`ifndef L1_CACHE_SV
`define L1_CACHE_SV

`timescale 1ns/1ps

// Blocking write-back / write-allocate L1 data cache with MESI coherence.
//
// Ownership of the shared bus is atomic, so this cache is never snooped while
// it holds a grant. That removes MESI transient states: every line is in
// exactly one of I/S/E/M at every clock edge.
module l1_cache #(
  parameter int unsigned CORE_ID = 0
) (
  input logic  clk,
  input logic  rst_n,
  core_if.dut  core,
  bus_if       bus
);

  import cache_pkg::*;

  // One request is serviced at a time. LOOKUP resolves hit/miss, WB drains a
  // dirty victim, BUS acquires permission and/or data, RESP returns the word.
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_WB,
    ST_BUS,
    ST_RESP
  } fsm_e;

  // Tag, state, data and replacement storage. Flat arrays rather than SRAM
  // macros so the whole cache state is directly observable to the testbench.
  mesi_e state_q [NUM_SETS][NUM_WAYS];
  tag_t  tag_q   [NUM_SETS][NUM_WAYS];
  line_t data_q  [NUM_SETS][NUM_WAYS];
  plru_t plru_q  [NUM_SETS];

  // The in-flight request, latched at accept so the core may drop its inputs.
  fsm_e  fsm_q;
  addr_t rq_addr_q;
  logic  rq_we_q;
  strb_t rq_be_q;
  data_t rq_wdata_q;
  way_t  vic_q;       // way this request will install into
  data_t rsp_data_q;

  // Registered snoop response, held until the snoop is withdrawn.
  logic  sn_ack_q;
  logic  sn_hit_q;
  logic  sn_pd_q;
  line_t sn_data_q;

  // ---------------------------------------------------------------- lookup
  // Parallel tag compare across every way of the indexed set. Recomputed every
  // cycle rather than latched, so a snoop that steals the line is seen
  // immediately by the bus-request logic below.

  index_t    rq_idx;
  tag_t      rq_tag;
  word_sel_t rq_word;
  logic      hit;
  way_t      hit_way;
  mesi_e     hit_state;
  way_t      vic_way;

  always_comb begin
    rq_idx    = addr_index(rq_addr_q);
    rq_tag    = addr_tag(rq_addr_q);
    rq_word   = addr_word(rq_addr_q);
    hit       = 1'b0;
    hit_way   = '0;
    hit_state = MESI_I;
    for (int unsigned w = 0; w < NUM_WAYS; w++) begin
      if (state_q[rq_idx][w] != MESI_I && tag_q[rq_idx][w] == rq_tag) begin
        hit       = 1'b1;
        hit_way   = way_t'(w);
        hit_state = state_q[rq_idx][w];
      end
    end
  end

  // Invalid ways are preferred over the PLRU choice; descending scan makes the
  // lowest invalid way win so the decision is deterministic.
  always_comb begin
    vic_way = plru_victim(plru_q[rq_idx]);
    for (int unsigned w = NUM_WAYS; w > 0; w--) begin
      if (state_q[rq_idx][w-1] == MESI_I) vic_way = way_t'(w-1);
    end
  end

  // ------------------------------------------------------------ bus request
  // What this cache needs from the bus, derived from live state every cycle.
  // DECISION: the operation is not latched when the request is raised. If a
  // snoop invalidates us while we queue, a pending CleanUnique silently becomes
  // a ReadUnique and a pending WriteBack withdraws. 

  logic    bus_req_c;
  bus_op_e bus_op_c;
  addr_t   bus_addr_c;
  logic    wb_needed;

`ifdef BUG_4
  assign wb_needed = 1'b0;
`else
  assign wb_needed = (state_q[rq_idx][vic_q] == MESI_M);
`endif

  always_comb begin
    bus_req_c  = 1'b0;
    bus_op_c   = BUS_READ_SHARED;
    bus_addr_c = line_addr(rq_addr_q);

    case (fsm_q)
      ST_WB: begin
        bus_req_c  = wb_needed;
        bus_op_c   = BUS_WRITEBACK;
        bus_addr_c = make_addr(tag_q[rq_idx][vic_q], rq_idx);
      end
      // Op is re-derived every cycle, so an intervening snoop that steals the
      // line downgrades a pending CleanUnique into a ReadUnique.
      ST_BUS: begin
        bus_req_c = 1'b1;
        if (!rq_we_q)                        bus_op_c = BUS_READ_SHARED;
        else if (hit && hit_state == MESI_S) bus_op_c = BUS_CLEAN_UNIQUE;
        else                                 bus_op_c = BUS_READ_UNIQUE;
      end
      default: ;
    endcase
  end

  assign bus.req[CORE_ID]   = bus_req_c;
  assign bus.op[CORE_ID]    = bus_op_c;
  assign bus.addr[CORE_ID]  = bus_addr_c;
  assign bus.wdata[CORE_ID] = data_q[rq_idx][vic_q];

  logic bus_done;
  assign bus_done = bus.gnt[CORE_ID] && bus.rsp_valid[CORE_ID];

  // ------------------------------------------------------------ fill result
  // What actually lands in the array when the bus transaction completes.
  // An upgrade keeps the data it already has; everything else takes the line
  // from the bus. A store then merges its bytes in and forces M.

  line_t fill_line;
  mesi_e fill_state;
  line_t commit_line;
  mesi_e commit_state;

  always_comb begin
    fill_line = (bus_op_c == BUS_CLEAN_UNIQUE) ? data_q[rq_idx][vic_q] : bus.rsp_data;

    case (bus_op_c)
`ifdef BUG_5
      BUS_READ_SHARED: fill_state = MESI_E;
`else
      BUS_READ_SHARED: fill_state = bus.rsp_shared ? MESI_S : MESI_E;
`endif
      default:         fill_state = MESI_M;
    endcase

    commit_line  = fill_line;
    commit_state = fill_state;
    if (rq_we_q) begin
      commit_line  = line_set_word(fill_line, int'(rq_word), rq_wdata_q, rq_be_q);
      commit_state = MESI_M;
    end
  end

  // ----------------------------------------------------------------- snoop
  // Independent lookup on the snooped address, so snoop handling does not have
  // to wait for the core-side request to finish.

  index_t sn_idx;
  tag_t   sn_tag;
  logic   sn_hit;
  way_t   sn_way;
  mesi_e  sn_state;
  logic   sn_active;
  logic   snoopable;
  logic   sn_take;

  always_comb begin
    sn_idx   = addr_index(bus.snoop_addr);
    sn_tag   = addr_tag(bus.snoop_addr);
    sn_hit   = 1'b0;
    sn_way   = '0;
    sn_state = MESI_I;
    for (int unsigned w = 0; w < NUM_WAYS; w++) begin
      if (state_q[sn_idx][w] != MESI_I && tag_q[sn_idx][w] == sn_tag) begin
        sn_hit   = 1'b1;
        sn_way   = way_t'(w);
        sn_state = state_q[sn_idx][w];
      end
    end
  end

  assign sn_active = bus.snoop_valid && bus.snoop_sel[CORE_ID];
  // ST_LOOKUP is the one cycle where the core path writes the arrays without
  // holding a grant, so the snoop waits it out. Bounded by one cycle.
  assign snoopable = (fsm_q != ST_LOOKUP);
  assign sn_take   = sn_active && snoopable && !sn_ack_q;

  // Gated by sn_active: sn_ack_q is registered and clears a cycle after the
  // snoop is withdrawn, so ungated it would assert while unselected. 
  assign bus.snoop_ack[CORE_ID]        = sn_ack_q && sn_active;
  assign bus.snoop_hit[CORE_ID]        = sn_hit_q;
  assign bus.snoop_pass_dirty[CORE_ID] = sn_pd_q;
  assign bus.snoop_data[CORE_ID]       = sn_data_q;

  // ------------------------------------------------------------- core ports
  // gnt is asserted whenever idle, which OBI permits; the transfer happens on
  // req && gnt. rvalid is the single-cycle response pulse.

  assign core.gnt    = (fsm_q == ST_IDLE);
  assign core.rvalid = (fsm_q == ST_RESP);
  assign core.rdata  = rsp_data_q;

  // ------------------------------------------------------------- sequential
  // Single process owns the arrays. The snoop update runs first and the core
  // FSM second; they can never target the same element because ST_LOOKUP is
  // not snoopable and a granted cache is not snooped.

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned s = 0; s < NUM_SETS; s++) begin
        plru_q[s] <= '0;
        for (int unsigned w = 0; w < NUM_WAYS; w++) begin
          state_q[s][w] <= MESI_I;
          tag_q[s][w]   <= '0;
          data_q[s][w]  <= '0;
        end
      end
      fsm_q      <= ST_IDLE;
      rq_addr_q  <= '0;
      rq_we_q    <= 1'b0;
      rq_be_q    <= '0;
      rq_wdata_q <= '0;
      vic_q      <= '0;
      rsp_data_q <= '0;
      sn_ack_q   <= 1'b0;
      sn_hit_q   <= 1'b0;
      sn_pd_q    <= 1'b0;
      sn_data_q  <= '0;
    end else begin

      // Snoop: answer once per broadcast and apply the MESI downgrade. The data
      // is captured before the state change so the requester sees the value the
      // line had when it was snooped.
      if (!sn_active) begin
        sn_ack_q <= 1'b0;
      end else if (sn_take) begin
        sn_ack_q  <= 1'b1;
        sn_hit_q  <= sn_hit;
        sn_pd_q   <= sn_hit && (sn_state == MESI_M) && (bus.snoop_op != BUS_CLEAN_UNIQUE);
        sn_data_q <= data_q[sn_idx][sn_way];
        if (sn_hit) begin
          case (bus.snoop_op)
`ifdef BUG_1
            BUS_READ_SHARED:  state_q[sn_idx][sn_way] <= MESI_E;
`else
            BUS_READ_SHARED:  state_q[sn_idx][sn_way] <= MESI_S;
`endif
            BUS_READ_UNIQUE:  state_q[sn_idx][sn_way] <= MESI_I;
`ifdef BUG_2
            BUS_CLEAN_UNIQUE: state_q[sn_idx][sn_way] <= state_q[sn_idx][sn_way];
`else
            BUS_CLEAN_UNIQUE: state_q[sn_idx][sn_way] <= MESI_I;
`endif
            default: ;
          endcase
        end
      end

      case (fsm_q)
        // Accept one request and latch it.
        ST_IDLE: begin
          if (core.req) begin
            rq_addr_q  <= core.addr;
            rq_we_q    <= core.we;
            rq_be_q    <= core.be;
            rq_wdata_q <= core.wdata;
            fsm_q      <= ST_LOOKUP;
          end
        end

        // Resolve the access. Loads and stores that already hold write
        // permission complete here with no bus traffic at all, including the
        // silent E->M upgrade.
        // DECISION: vic_q is latched on every path, set to hit_way on the
        // upgrade path. That way the fill target is always vic_q even when an
        // intervening snoop turns the upgrade into a full refill.
        ST_LOOKUP: begin
          vic_q <= hit ? hit_way : vic_way;
          if (hit && (!rq_we_q || hit_state != MESI_S)) begin
            if (rq_we_q) begin
`ifdef BUG_3
              data_q[rq_idx][hit_way]  <= line_set_word(data_q[rq_idx][hit_way],
                                                        int'(rq_word), rq_wdata_q, '1);
`else
              data_q[rq_idx][hit_way]  <= line_set_word(data_q[rq_idx][hit_way],
                                                        int'(rq_word), rq_wdata_q, rq_be_q);
`endif
              state_q[rq_idx][hit_way] <= MESI_M;
            end else begin
              rsp_data_q <= line_get_word(data_q[rq_idx][hit_way], int'(rq_word));
            end
            plru_q[rq_idx] <= plru_update(plru_q[rq_idx], hit_way);
            fsm_q <= ST_RESP;
          end else if (hit && rq_we_q && hit_state == MESI_S) begin
            fsm_q <= ST_BUS;
          end else begin
            fsm_q <= ST_WB;
          end
        end

        // Drain a dirty victim before reusing its way. Skipped entirely if the
        // victim is clean (a silent eviction), which MESI permits.
        ST_WB: begin
          if (!wb_needed) begin
            fsm_q <= ST_BUS;
          end else if (bus_done) begin
            state_q[rq_idx][vic_q] <= MESI_I;
            fsm_q                  <= ST_BUS;
          end
        end

        // Wait for permission and/or data, then commit tag, state, data, PLRU
        // and the response word in one atomic array update.
        ST_BUS: begin
          if (bus_done) begin
            data_q[rq_idx][vic_q]  <= commit_line;
            tag_q[rq_idx][vic_q]   <= rq_tag;
            state_q[rq_idx][vic_q] <= commit_state;
            plru_q[rq_idx]         <= plru_update(plru_q[rq_idx], vic_q);
            rsp_data_q             <= line_get_word(commit_line, int'(rq_word));
            fsm_q                  <= ST_RESP;
          end
        end

        ST_RESP: begin
          fsm_q <= ST_IDLE;
        end

        default: fsm_q <= ST_IDLE;
      endcase
    end
  end

  initial begin
    if (NUM_WAYS != (1 << WAY_W)) $fatal(1, "l1_cache: NUM_WAYS must be a power of two");
    if (LINE_WORDS < 2)           $fatal(1, "l1_cache: LINE_WORDS must be >= 2");
  end

endmodule

`endif

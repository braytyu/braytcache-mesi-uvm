`ifndef COHERENCE_BUS_SV
`define COHERENCE_BUS_SV

`timescale 1ns/1ps

// Atomic snooping interconnect. One master is granted at a time; the grant is
// held across snoop, memory access and response, so no cache ever observes a
// snoop to a line it is concurrently fetching.
module coherence_bus (
  input logic  clk,
  input logic  rst_n,
  bus_if       bus,
  axil_if.mst  mem
);

  import cache_pkg::*;

  // One transaction walks this FSM start to finish before the next is granted.
  // B_SNOOP collects snoop results, the B_MEM_* states move a line to or from
  // memory a word at a time, B_DONE hands the result back to the requester.
  typedef enum logic [2:0] {
    B_IDLE,
    B_SNOOP,
    B_MEM_RD,
    B_MEM_WR,
    B_DONE
  } bstate_e;

  // Per-transaction context, latched once at grant and held to completion.
  bstate_e                bst_q;
  logic [CORE_ID_W-1:0]   cur_q;      // granted master
  logic [CORE_ID_W-1:0]   last_q;     // round-robin pointer
  bus_op_e                op_q;
  addr_t                  addr_q;
  line_t                  line_q;     // line buffer: writeback data, fill data or snoop data
  logic                   shared_q;   // IsShared to return to the requester
  logic [WORD_SEL_W:0]    beat_q;     // which word of the line the AXI side is on
  logic                   ar_done_q;
  logic                   aw_done_q;
  logic                   w_done_q;

  // ---------------------------------------------------------------- arbiter
  // Round-robin: start scanning one past whoever went last, take the first
  // requester found.
  // DECISION: round-robin rather than fixed priority so neither core can be
  // starved. Under pingpong stimulus a fixed-priority arbiter would let one
  // core monopolise a contended line and hide the migration cases entirely.

  logic                 win_val;
  logic [CORE_ID_W-1:0] win;
  int unsigned          arb_idx;

  always_comb begin
    win_val = 1'b0;
    win     = '0;
    arb_idx = 0;
    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      arb_idx = (int'(last_q) + 1 + i) % NUM_CORES;
      if (!win_val && bus.req[arb_idx]) begin
        win_val = 1'b1;
        win     = arb_idx[CORE_ID_W-1:0];
      end
    end
  end

  // ------------------------------------------------------------ snoop fabric
  // Every cache except the requester is selected, and the transaction stalls in
  // B_SNOOP until all of them have acknowledged.
  // DECISION: excluding the requester is what guarantees a cache is never
  // snooped while it holds a grant, which is the entire reason MESI here needs
  // no transient states.

  logic  snoop_sel_c [NUM_CORES];
  logic  sn_all_ack;
  logic  sn_any_hit;
  logic  sn_any_pd;
  line_t sn_pd_data;

  always_comb begin
    for (int unsigned i = 0; i < NUM_CORES; i++)
      snoop_sel_c[i] = (bst_q == B_SNOOP) && (i != int'(cur_q));
  end

  // Reduce the per-cache snoop responses into the three facts the transaction
  // needs: everyone has answered, somebody had the line, somebody had it dirty.
  always_comb begin
    sn_all_ack = 1'b1;
    sn_any_hit = 1'b0;
    sn_any_pd  = 1'b0;
    sn_pd_data = '0;
    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      if (snoop_sel_c[i]) begin
        if (!bus.snoop_ack[i]) sn_all_ack = 1'b0;
        if (bus.snoop_ack[i] && bus.snoop_hit[i]) sn_any_hit = 1'b1;
        if (bus.snoop_ack[i] && bus.snoop_pass_dirty[i]) begin
          sn_any_pd  = 1'b1;
          sn_pd_data = bus.snoop_data[i];
        end
      end
    end
  end

  // Grant is held for the whole transaction; rsp_valid is the single completion
  // pulse the requester commits on.
  always_comb begin
    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      bus.gnt[i]       = (bst_q != B_IDLE) && (i == int'(cur_q));
      bus.rsp_valid[i] = (bst_q == B_DONE) && (i == int'(cur_q));
      bus.snoop_sel[i] = snoop_sel_c[i];
    end
  end

  assign bus.snoop_valid = (bst_q == B_SNOOP);
  assign bus.snoop_op    = op_q;
  assign bus.snoop_addr  = addr_q;
  assign bus.rsp_data    = line_q;
  assign bus.rsp_shared  = shared_q;

  // -------------------------------------------------------- AXI4-Lite master
  // A cache line is moved as LINE_WORDS single-beat transactions, indexed by
  // beat_q. Valids are gated on the state so they drop automatically on exit.
  // DECISION: AXI4-Lite has no bursts, so a fill is several transactions rather
  // than one. 
  
  assign mem.awvalid = (bst_q == B_MEM_WR) && !aw_done_q;
  assign mem.wvalid  = (bst_q == B_MEM_WR) && !w_done_q;
  assign mem.bready  = (bst_q == B_MEM_WR);
  assign mem.arvalid = (bst_q == B_MEM_RD) && !ar_done_q;
  assign mem.rready  = (bst_q == B_MEM_RD);
  assign mem.awaddr  = addr_t'(addr_q + (int'(beat_q) * STRB_W));
  assign mem.araddr  = addr_t'(addr_q + (int'(beat_q) * STRB_W));
  assign mem.wdata   = line_get_word(line_q, int'(beat_q));
  assign mem.wstrb   = '1;
  assign mem.awprot  = 3'b000;
  assign mem.arprot  = 3'b000;

  logic last_beat;
  assign last_beat = (int'(beat_q) == LINE_WORDS - 1);

  // ------------------------------------------------------------- sequential

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bst_q     <= B_IDLE;
      cur_q     <= '0;
      last_q    <= '0;
      op_q      <= BUS_READ_SHARED;
      addr_q    <= '0;
      line_q    <= '0;
      shared_q  <= 1'b0;
      beat_q    <= '0;
      ar_done_q <= 1'b0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else begin
      case (bst_q)
        // Latch the winner's request. A writeback needs no snoop because the
        // requester held the line M, so by SWMR nobody else can have it.
        B_IDLE: begin
          if (win_val) begin
            cur_q    <= win;
            last_q   <= win;
            op_q     <= bus.op[win];
            addr_q   <= line_addr(bus.addr[win]);
            line_q   <= bus.wdata[win];
            shared_q <= 1'b0;
            beat_q   <= '0;
            bst_q    <= (bus.op[win] == BUS_WRITEBACK) ? B_MEM_WR : B_SNOOP;
          end
        end

        // Decide where the data comes from once every snooper has answered.
        B_SNOOP: begin
          if (sn_all_ack) begin
            shared_q <= sn_any_hit;
            if (sn_any_pd) line_q <= sn_pd_data;

            case (op_q)
              BUS_CLEAN_UNIQUE: bst_q <= B_DONE;
              BUS_READ_UNIQUE:  bst_q <= sn_any_pd ? B_DONE : B_MEM_RD;
              // A dirty snoop hit satisfies the requester directly, but MESI
              // requires memory to be clean once the line becomes shared.
              BUS_READ_SHARED:  bst_q <= sn_any_pd ? B_MEM_WR : B_MEM_RD;
              default:          bst_q <= B_MEM_RD;
            endcase
          end
        end

        // Fill: one AXI read per word, accumulated into the line buffer.
        B_MEM_RD: begin
          if (mem.arvalid && mem.arready) ar_done_q <= 1'b1;
          if (mem.rvalid) begin
            line_q[int'(beat_q)*DATA_W +: DATA_W] <= mem.rdata;
            ar_done_q <= 1'b0;
            if (last_beat) begin
              beat_q <= '0;
              bst_q  <= B_DONE;
            end else begin
              beat_q <= beat_q + 1'b1;
            end
          end
        end

        // Writeback or memory update: one AXI write per word.
        B_MEM_WR: begin
          if (mem.awvalid && mem.awready) aw_done_q <= 1'b1;
          if (mem.wvalid  && mem.wready)  w_done_q  <= 1'b1;
          if (mem.bvalid) begin
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            if (last_beat) begin
              beat_q <= '0;
              bst_q  <= B_DONE;
            end else begin
              beat_q <= beat_q + 1'b1;
            end
          end
        end

        // Single completion cycle, then release the bus.
        B_DONE: begin
          bst_q <= B_IDLE;
        end

        default: bst_q <= B_IDLE;
      endcase
    end
  end

endmodule

`endif

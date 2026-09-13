`ifndef COHERENCE_SCOREBOARD_SV
`define COHERENCE_SCOREBOARD_SV

class coherence_scoreboard extends uvm_scoreboard;

  // Three independent streams feed the checking: what the cores saw, what moved
  // on the coherent bus, and how cache state actually changed.
  uvm_analysis_imp_core  #(core_item,  coherence_scoreboard) core_imp;
  uvm_analysis_imp_bus   #(bus_item,   coherence_scoreboard) bus_imp;
  uvm_analysis_imp_probe #(probe_item, coherence_scoreboard) probe_imp;

  virtual cache_probe_if probe_vif [NUM_CORES];
  mem_model              mem;

  // Global-order reference memory. Coherence serialises same-address accesses,
  // so applying core transactions in completion order is well defined.
  protected data_t gold [addr_t];

  // Per-line tally used by the SWMR sweep.
  typedef struct {
    int unsigned m_cnt;
    int unsigned e_cnt;
    int unsigned s_cnt;
    bit          have_data;
    line_t       ref_data;
    int unsigned ref_core;
  } census_t;

  protected bit          check_pending;
  protected int unsigned n_loads;
  protected int unsigned n_stores;
  protected int unsigned n_bus_op [4];
  protected int unsigned n_transitions;
  protected int unsigned n_census;
  protected int unsigned max_reported_final_errors = 20;

  `uvm_component_utils(coherence_scoreboard)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    core_imp  = new("core_imp",  this);
    bus_imp   = new("bus_imp",   this);
    probe_imp = new("probe_imp", this);
  endfunction

  // ------------------------------------------------------------ core stream
  // Data-value invariant: stores update the reference memory, loads are checked
  // against it. Items arrive in completion order, which is a valid global order
  // because coherence serialises same-address accesses.

  function void write_core(core_item it);
    addr_t k;
    k = mem_model::word_key(it.addr);
    if (!gold.exists(k)) gold[k] = mem_model::backing_value(k);

    if (it.op == CORE_STORE) begin
      n_stores++;
      gold[k] = merge_bytes(gold[k], it.wdata, it.be);
    end else begin
      n_loads++;
      if (it.rdata !== gold[k])
        `uvm_error("SB_DATA", $sformatf("load mismatch: %s expected=0x%08h",
                                        it.convert2string(), gold[k]))
    end
  endfunction

  // ------------------------------------------------------------- bus stream
  // Checks the interconnect's own aggregation logic rather than the caches.

  function void write_bus(bus_item it);
    n_bus_op[int'(it.op)]++;

    if (it.op == BUS_READ_SHARED && it.shared != it.any_hit())
      `uvm_error("SB_BUS", $sformatf("IsShared inconsistent with snoop hits: %s",
                                     it.convert2string()))

    if (it.any_pass_dirty() && it.op == BUS_CLEAN_UNIQUE)
      `uvm_error("SB_BUS", $sformatf("upgrade must not move data: %s", it.convert2string()))
  endfunction

  // ----------------------------------------------------------- probe stream
  // Legality of every observed state change. Catching an illegal transition at
  // the moment it happens is far cheaper to debug than waiting for it to
  // surface as a wrong load thousands of cycles later.

  function bit legal_transition(mesi_e o, mesi_e n, bit tag_changed);
    // A tag change is an allocation into the way. The previous occupant must
    // have been clean, otherwise dirty data was dropped without a writeback.
    if (tag_changed) return (o != MESI_M) && (n != MESI_I);

    case (o)
      MESI_I:  return (n == MESI_S) || (n == MESI_E) || (n == MESI_M);
      MESI_S:  return (n == MESI_I) || (n == MESI_M);
      MESI_E:  return (n == MESI_I) || (n == MESI_S) || (n == MESI_M);
      MESI_M:  return (n == MESI_I) || (n == MESI_S);
      default: return 1'b0;
    endcase
  endfunction

  function void write_probe(probe_item it);
    bit tag_changed;
    n_transitions++;
    check_pending = 1'b1;

    tag_changed = (it.old_tag !== it.new_tag);

    if (!legal_transition(it.old_state, it.new_state, tag_changed))
      `uvm_error("SB_MESI", $sformatf("illegal MESI transition: %s (tag_changed=%0b)",
                                      it.convert2string(), tag_changed))
  endfunction

  // ------------------------------------------------------ SWMR / share check
  // DECISION: the sweep is gated on check_pending rather than run every cycle.
  // States only move when the probe stream reports a transition, so this is
  // complete but avoids rebuilding the census on idle cycles.

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge probe_vif[0].clk);
      if (probe_vif[0].rst_n === 1'b1 && check_pending) begin
        check_pending = 1'b0;
        check_invariants();
      end
    end
  endtask

  function void check_invariants();
    census_t c [addr_t];
    census_t e;
    addr_t   la;
    mesi_e   st;

    n_census++;

    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      for (int unsigned s = 0; s < NUM_SETS; s++) begin
        for (int unsigned w = 0; w < NUM_WAYS; w++) begin
          st = probe_vif[i].state[s][w];
          if (st == MESI_I) continue;

          la = make_addr(probe_vif[i].tag[s][w], index_t'(s));
          if (!c.exists(la))
            c[la] = '{m_cnt:0, e_cnt:0, s_cnt:0, have_data:1'b0, ref_data:'0, ref_core:0};

          e = c[la];
          case (st)
            MESI_M: e.m_cnt++;
            MESI_E: e.e_cnt++;
            MESI_S: e.s_cnt++;
            default: ;
          endcase

          // Every sharer of a line must hold identical data.
          if (st == MESI_S) begin
            if (!e.have_data) begin
              e.have_data = 1'b1;
              e.ref_data  = probe_vif[i].data[s][w];
              e.ref_core  = i;
            end else if (probe_vif[i].data[s][w] !== e.ref_data) begin
              `uvm_error("SB_SHARE",
                $sformatf("sharers disagree on line 0x%08h: c%0d vs c%0d", la, e.ref_core, i))
            end
          end

          c[la] = e;
        end
      end
    end

    foreach (c[a]) begin
      e = c[a];
      if ((e.m_cnt + e.e_cnt) > 1)
        `uvm_error("SB_SWMR",
          $sformatf("line 0x%08h has %0d M and %0d E owners (single-writer violated)",
                    a, e.m_cnt, e.e_cnt))
      if ((e.m_cnt + e.e_cnt) > 0 && e.s_cnt > 0)
        `uvm_error("SB_SWMR",
          $sformatf("line 0x%08h held exclusively while %0d sharers exist", a, e.s_cnt))
    end
  endfunction

  // ------------------------------------------------------ end of test check
  // Reconciles reference memory against the real system state: a line still
  // held dirty lives in that cache, everything else must be in memory. 

  function bit find_dirty_copy(addr_t a, output data_t val);
    addr_t la;
    la = line_addr(a);
    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      for (int unsigned s = 0; s < NUM_SETS; s++) begin
        for (int unsigned w = 0; w < NUM_WAYS; w++) begin
          if (probe_vif[i].state[s][w] == MESI_M &&
              make_addr(probe_vif[i].tag[s][w], index_t'(s)) == la) begin
            val = line_get_word(probe_vif[i].data[s][w], int'(addr_word(a)));
            return 1'b1;
          end
        end
      end
    end
    return 1'b0;
  endfunction

  function void check_phase(uvm_phase phase);
    data_t       actual;
    int unsigned errs;
    super.check_phase(phase);

    errs = 0;
    foreach (gold[k]) begin
      if (!find_dirty_copy(k, actual)) actual = mem.read(k);
      if (actual !== gold[k]) begin
        errs++;
        if (errs <= max_reported_final_errors)
          `uvm_error("SB_FINAL", $sformatf("addr 0x%08h expected=0x%08h actual=0x%08h",
                                           k, gold[k], actual))
      end
    end

    if (errs > max_reported_final_errors)
      `uvm_error("SB_FINAL", $sformatf("%0d further end-of-test mismatches suppressed",
                                       errs - max_reported_final_errors))
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SB", $sformatf(
      "\n  loads=%0d stores=%0d touched_words=%0d\n  ReadShared=%0d ReadUnique=%0d CleanUnique=%0d WriteBack=%0d\n  state transitions=%0d  invariant sweeps=%0d",
      n_loads, n_stores, gold.num(),
      n_bus_op[int'(BUS_READ_SHARED)], n_bus_op[int'(BUS_READ_UNIQUE)],
      n_bus_op[int'(BUS_CLEAN_UNIQUE)], n_bus_op[int'(BUS_WRITEBACK)],
      n_transitions, n_census), UVM_LOW)
  endfunction

endclass

`endif

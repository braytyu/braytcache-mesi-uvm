`ifndef CACHE_COVERAGE_SV
`define CACHE_COVERAGE_SV

class cache_coverage extends uvm_component;

  // Subscribes to every observation stream in the environment. Coverage is kept
  // out of the scoreboard so checking and sampling stay independent.
  uvm_analysis_imp_core  #(core_item,  cache_coverage) core_imp;
  uvm_analysis_imp_bus   #(bus_item,   cache_coverage) bus_imp;
  uvm_analysis_imp_probe #(probe_item, cache_coverage) probe_imp;
  uvm_analysis_imp_axil  #(axil_item,  cache_coverage) axil_imp;

  virtual cache_probe_if probe_vif [NUM_CORES];

  `uvm_component_utils(cache_coverage)

  // Stimulus shape as it reaches the cache: which set, which word, what kind of
  // byte enable. Confirms the sequences actually spread over the geometry.
  covergroup cg_core with function sample (core_op_e   op,
                                           int unsigned core_id,
                                           index_t      set_idx,
                                           word_sel_t   word,
                                           strb_t       be);
    option.per_instance = 1;
    option.name         = "cg_core";

    cp_op   : coverpoint op;
    cp_core : coverpoint core_id { bins c[] = {[0 : NUM_CORES-1]}; }
    cp_set  : coverpoint set_idx { bins s[] = {[0 : NUM_SETS-1]}; }
    cp_word : coverpoint word;
    cp_be   : coverpoint be {
      bins full      = {(1 << STRB_W) - 1};
      bins single[]  = {1, 2, 4, 8};
      bins partial   = default;
    }

    x_core_op : cross cp_core, cp_op;
    x_op_be   : cross cp_op, cp_be {
      ignore_bins loads_are_full = binsof(cp_op) intersect {CORE_LOAD} &&
                                   binsof(cp_be) intersect {1, 2, 4, 8};
    }
  endgroup

  // Coherent transaction outcomes, including dirty intervention, a snooper
  // supplying data instead of memory.
  covergroup cg_bus with function sample (bus_op_e     op,
                                          int unsigned core_id,
                                          bit          hit,
                                          bit          pass_dirty,
                                          bit          shared);
    option.per_instance = 1;
    option.name         = "cg_bus";

    cp_op     : coverpoint op;
    cp_core   : coverpoint core_id { bins c[] = {[0 : NUM_CORES-1]}; }
    cp_hit    : coverpoint hit;
    cp_pd     : coverpoint pass_dirty;
    cp_shared : coverpoint shared;

    x_op_core : cross cp_op, cp_core;
    x_op_hit  : cross cp_op, cp_hit;

    // Dirty intervention: a snooper supplying data instead of memory.
    x_op_pd : cross cp_op, cp_pd {
      ignore_bins no_data_moved = binsof(cp_op) intersect {BUS_CLEAN_UNIQUE, BUS_WRITEBACK} &&
                                  binsof(cp_pd) intersect {1};
    }

    x_share : cross cp_op, cp_shared {
      ignore_bins not_a_read = binsof(cp_op) intersect {BUS_CLEAN_UNIQUE, BUS_WRITEBACK};
    }
  endgroup

  // Every MESI transition, split by whether the tag also changed (an allocation)
  // so protocol moves and replacements are covered separately.
  covergroup cg_mesi with function sample (mesi_e       old_state,
                                           mesi_e       new_state,
                                           bit          tag_changed,
                                           int unsigned core_id);
    option.per_instance = 1;
    option.name         = "cg_mesi";

    cp_old  : coverpoint old_state;
    cp_new  : coverpoint new_state;
    cp_tagc : coverpoint tag_changed;
    cp_core : coverpoint core_id { bins c[] = {[0 : NUM_CORES-1]}; }

    x_trans : cross cp_old, cp_new, cp_tagc {
      // Same line, so only protocol transitions are reachable.
      illegal_bins s_to_e = binsof(cp_old) intersect {MESI_S} &&
                            binsof(cp_new) intersect {MESI_E} &&
                            binsof(cp_tagc) intersect {0};
      illegal_bins m_to_e = binsof(cp_old) intersect {MESI_M} &&
                            binsof(cp_new) intersect {MESI_E} &&
                            binsof(cp_tagc) intersect {0};
      // Allocating over a modified way means dirty data was dropped.
      illegal_bins dirty_dropped = binsof(cp_old) intersect {MESI_M} &&
                                   binsof(cp_tagc) intersect {1};

      // The probe only fires on a change, so a same-state same-tag sample can
      // never occur; and an allocation always installs a valid line.
      ignore_bins unchanged = binsof(cp_tagc) intersect {0} &&
                              ((binsof(cp_old) intersect {MESI_I} && binsof(cp_new) intersect {MESI_I}) ||
                               (binsof(cp_old) intersect {MESI_S} && binsof(cp_new) intersect {MESI_S}) ||
                               (binsof(cp_old) intersect {MESI_E} && binsof(cp_new) intersect {MESI_E}) ||
                               (binsof(cp_old) intersect {MESI_M} && binsof(cp_new) intersect {MESI_M}));

      ignore_bins alloc_to_invalid = binsof(cp_tagc) intersect {1} &&
                                     binsof(cp_new) intersect {MESI_I};
    }
  endgroup

  // Two-cache state pair for one line. The point of this cross is its illegal
  // bins: they enumerate every combination MESI forbids.
  covergroup cg_share with function sample (mesi_e s0, mesi_e s1);
    option.per_instance = 1;
    option.name         = "cg_share";

    cp_c0 : coverpoint s0;
    cp_c1 : coverpoint s1;

    x_pair : cross cp_c0, cp_c1 {
      illegal_bins mm = binsof(cp_c0) intersect {MESI_M} && binsof(cp_c1) intersect {MESI_M};
      illegal_bins me = binsof(cp_c0) intersect {MESI_M} && binsof(cp_c1) intersect {MESI_E};
      illegal_bins ms = binsof(cp_c0) intersect {MESI_M} && binsof(cp_c1) intersect {MESI_S};
      illegal_bins em = binsof(cp_c0) intersect {MESI_E} && binsof(cp_c1) intersect {MESI_M};
      illegal_bins ee = binsof(cp_c0) intersect {MESI_E} && binsof(cp_c1) intersect {MESI_E};
      illegal_bins es = binsof(cp_c0) intersect {MESI_E} && binsof(cp_c1) intersect {MESI_S};
      illegal_bins sm = binsof(cp_c0) intersect {MESI_S} && binsof(cp_c1) intersect {MESI_M};
      illegal_bins se = binsof(cp_c0) intersect {MESI_S} && binsof(cp_c1) intersect {MESI_E};
    }
  endgroup

  // Which way was replaced and what was in it. Distinguishes allocation into a
  // free way from a real PLRU-driven eviction, so both paths are proven to run.
  covergroup cg_alloc with function sample (mesi_e       victim_state,
                                            int unsigned way,
                                            index_t      set_idx,
                                            int unsigned core_id);
    option.per_instance = 1;
    option.name         = "cg_alloc";

    cp_victim : coverpoint victim_state {
      bins free  = {MESI_I};
      bins clean_shared    = {MESI_S};
      bins clean_exclusive = {MESI_E};
      illegal_bins dirty   = {MESI_M};
    }
    cp_way  : coverpoint way     { bins w[] = {[0 : NUM_WAYS-1]}; }
    cp_set  : coverpoint set_idx { bins s[] = {[0 : NUM_SETS-1]}; }
    cp_core : coverpoint core_id { bins c[] = {[0 : NUM_CORES-1]}; }

    x_victim_way : cross cp_victim, cp_way;
    x_way_core   : cross cp_way, cp_core;
  endgroup

  // Proves every word position of a line is both fetched and written back.
  covergroup cg_axil with function sample (bit is_write, word_sel_t beat);
    option.per_instance = 1;
    option.name         = "cg_axil";

    cp_dir  : coverpoint is_write { bins read = {0}; bins write = {1}; }
    cp_beat : coverpoint beat     { bins b[] = {[0 : LINE_WORDS-1]}; }

    x_dir_beat : cross cp_dir, cp_beat;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    core_imp  = new("core_imp",  this);
    bus_imp   = new("bus_imp",   this);
    probe_imp = new("probe_imp", this);
    axil_imp  = new("axil_imp",  this);

    cg_core  = new();
    cg_bus   = new();
    cg_mesi  = new();
    cg_alloc = new();
    cg_axil  = new();
    if (NUM_CORES == 2) cg_share = new();
  endfunction

  function void write_axil(axil_item it);
    cg_axil.sample(it.is_write, addr_word(it.addr));
  endfunction

  function void write_core(core_item it);
    cg_core.sample(it.op, it.core_id, addr_index(it.addr), addr_word(it.addr), it.be);
  endfunction

  function void write_bus(bus_item it);
    cg_bus.sample(it.op, it.core_id, it.any_hit(), it.any_pass_dirty(), it.shared);
  endfunction

  // Resolves the state of a line in one cache, for the cross-cache pair sample.
  function mesi_e state_of(int unsigned core, addr_t la);
    index_t s;
    tag_t   t;
    s = addr_index(la);
    t = addr_tag(la);
    for (int unsigned w = 0; w < NUM_WAYS; w++)
      if (probe_vif[core].state[s][w] != MESI_I && probe_vif[core].tag[s][w] == t)
        return probe_vif[core].state[s][w];
    return MESI_I;
  endfunction

  function void write_probe(probe_item it);
    bit tag_changed;
    tag_changed = (it.old_tag !== it.new_tag);

    cg_mesi.sample(it.old_state, it.new_state, tag_changed, it.core_id);

    // A way is being installed with a line: it was free, or a different line 
    // is displacing it. A tag change alone misses a fill into an invalid way 
    // whose stale tag already matches the incoming one. 
    if (it.new_state != MESI_I && (tag_changed || it.old_state == MESI_I))
      cg_alloc.sample(it.old_state, it.way_idx, index_t'(it.set_idx), it.core_id);

    if (cg_share != null)
      cg_share.sample(state_of(0, it.new_line_addr()), state_of(1, it.new_line_addr()));
  endfunction

  // DECISION: coverage is reported from the testbench rather than a tool
  // database, so the numbers survive flows with no UCDB or merge support.
  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    `uvm_info("COV", "---------------- functional coverage ----------------", UVM_NONE)
    `uvm_info("COV", $sformatf("  cg_core   %6.2f %%", cg_core.get_inst_coverage()),  UVM_NONE)
    `uvm_info("COV", $sformatf("  cg_bus    %6.2f %%", cg_bus.get_inst_coverage()),   UVM_NONE)
    `uvm_info("COV", $sformatf("  cg_mesi   %6.2f %%", cg_mesi.get_inst_coverage()),  UVM_NONE)
    `uvm_info("COV", $sformatf("  cg_alloc  %6.2f %%", cg_alloc.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("  cg_axil   %6.2f %%", cg_axil.get_inst_coverage()),  UVM_NONE)
    if (cg_share != null)
      `uvm_info("COV", $sformatf("  cg_share  %6.2f %%", cg_share.get_inst_coverage()), UVM_NONE)
    `uvm_info("COV", $sformatf("  OVERALL   %6.2f %%", $get_coverage()), UVM_NONE)
    `uvm_info("COV", "----------------------------------------------------", UVM_NONE)
  endfunction

endclass

`endif

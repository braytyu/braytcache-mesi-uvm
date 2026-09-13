`ifndef CACHE_VSEQ_LIB_SV
`define CACHE_VSEQ_LIB_SV

// Base virtual sequence: forks one core-level sequence per core and waits for
// all of them. Subclasses override run_core_seq().
class cache_base_vseq extends uvm_sequence;

  rand int unsigned num_txns;
  rand int unsigned store_pct;

  addr_t region_lo = 32'h0000_0000;
  addr_t region_hi = 32'h0000_0fff;

  constraint c_num_txns  { soft num_txns inside {[40:90]}; num_txns > 0; }
  constraint c_store_pct { soft store_pct inside {[20:80]}; store_pct <= 100; }

  `uvm_object_utils(cache_base_vseq)
  `uvm_declare_p_sequencer(cache_vsequencer)

  function new(string name = "cache_base_vseq");
    super.new(name);
  endfunction

  virtual task body();
    // Nested fork so wait fork covers only the per-core processes.
    fork begin
      for (int unsigned i = 0; i < NUM_CORES; i++) begin
        automatic int unsigned c = i;
        fork
          run_core_seq(c);
        join_none
      end
      wait fork;
    end join 
  endtask

  // The single extension point: subclasses swap in a different core sequence
  // and inherit the forking, address region and length control unchanged.
  virtual task run_core_seq(int unsigned c);
    core_base_seq s;
    s = core_base_seq::type_id::create($sformatf("core%0d_seq", c));
    s.region_lo = region_lo;
    s.region_hi = region_hi;
    if (!s.randomize() with { num_txns  == local::num_txns;
                              store_pct == local::store_pct; })
      `uvm_error(get_type_name(), "core_base_seq randomize failed")
    s.start(p_sequencer.core_sqr[c]);
  endtask

  // One blocking access on one core. start() does not return until the driver has seen rvalid.
  protected task do_access(int unsigned core, core_op_e a_op, addr_t a_addr, data_t a_data);
    core_single_seq s;
    s = core_single_seq::type_id::create("directed");
    if (!s.randomize() with { op    == a_op;
                              addr  == a_addr;
                              wdata == a_data;
                              be    == '1;
                              pre_delay == 0; })
      `uvm_error(get_type_name(), "core_single_seq randomize failed")
    s.start(p_sequencer.core_sqr[core]);
  endtask

endclass


class random_vseq extends cache_base_vseq;
  `uvm_object_utils(random_vseq)
  function new(string name = "random_vseq");
    super.new(name);
  endfunction
endclass


class shared_region_vseq extends cache_base_vseq;
  `uvm_object_utils(shared_region_vseq)
  function new(string name = "shared_region_vseq");
    super.new(name);
    region_lo = 32'h0000_0000;
    region_hi = addr_t'(4 * LINE_BYTES - 1);
  endfunction
endclass


// Same line w/different words: invalidations with no real data sharing.
class false_sharing_vseq extends cache_base_vseq;

  rand addr_t shared_line;

  constraint c_line {
    shared_line[OFFSET_W-1:0] == '0;
    shared_line inside {[region_lo : region_hi]};
  }

  `uvm_object_utils(false_sharing_vseq)

  function new(string name = "false_sharing_vseq");
    super.new(name);
  endfunction

  virtual task run_core_seq(int unsigned c);
    core_line_seq s;
    s = core_line_seq::type_id::create($sformatf("core%0d_line_seq", c));
    s.region_lo = region_lo;
    s.region_hi = region_hi;
    if (!s.randomize() with { line_base == local::shared_line;
                              num_txns  == local::num_txns;
                              store_pct == local::store_pct; })
      `uvm_error(get_type_name(), "core_line_seq randomize failed")
    s.start(p_sequencer.core_sqr[c]);
  endtask

endclass


// Single word hammered by both cores: ownership migrates on nearly every access.
class pingpong_vseq extends cache_base_vseq;

  rand addr_t target;

  constraint c_target {
    target[BYTE_OFF_W-1:0] == '0;
    target inside {[region_lo : region_hi]};
  }
  constraint c_mix { store_pct inside {[40:60]}; }

  `uvm_object_utils(pingpong_vseq)

  function new(string name = "pingpong_vseq");
    super.new(name);
  endfunction

  virtual task run_core_seq(int unsigned c);
    core_pingpong_seq s;
    s = core_pingpong_seq::type_id::create($sformatf("core%0d_pp_seq", c));
    s.region_lo = region_lo;
    s.region_hi = region_hi;
    if (!s.randomize() with { target    == local::target;
                              num_txns  == local::num_txns;
                              store_pct == local::store_pct; })
      `uvm_error(get_type_name(), "core_pingpong_seq randomize failed")
    s.start(p_sequencer.core_sqr[c]);
  endtask

endclass


// Both cores thrash the same set with more tags than ways.
class eviction_vseq extends cache_base_vseq;

  rand index_t target_set;

  constraint c_stores { soft store_pct inside {[50:90]}; }

  `uvm_object_utils(eviction_vseq)

  function new(string name = "eviction_vseq");
    super.new(name);
  endfunction

  virtual task run_core_seq(int unsigned c);
    core_set_conflict_seq s;
    s = core_set_conflict_seq::type_id::create($sformatf("core%0d_conf_seq", c));
    s.region_lo = region_lo;
    s.region_hi = region_hi;
    if (!s.randomize() with { target_set == local::target_set;
                              num_txns   == local::num_txns;
                              store_pct  == local::store_pct; })
      `uvm_error(get_type_name(), "core_set_conflict_seq randomize failed")
    s.start(p_sequencer.core_sqr[c]);
  endtask

endclass


// Read-mostly traffic drives lines into S and keeps them there.
class read_mostly_vseq extends cache_base_vseq;

  `uvm_object_utils(read_mostly_vseq)

  function new(string name = "read_mostly_vseq");
    super.new(name);
    region_lo = 32'h0000_0000;
    region_hi = addr_t'(8 * LINE_BYTES - 1);
  endfunction

  virtual task run_core_seq(int unsigned c);
    core_read_only_seq s;
    s = core_read_only_seq::type_id::create($sformatf("core%0d_ro_seq", c));
    s.region_lo = region_lo;
    s.region_hi = region_hi;
    if (!s.randomize() with { num_txns == local::num_txns; })
      `uvm_error(get_type_name(), "core_read_only_seq randomize failed")
    s.start(p_sequencer.core_sqr[c]);
  endtask

endclass


// Bursts of stores to a single address, then a new address. Exercises the
// silent E->M upgrade and long runs of M hits that produce no bus traffic,
// separated by ownership migrations when the cores collide.
class store_streak_vseq extends cache_base_vseq;

  rand int unsigned n_streaks;

  constraint c_streaks { n_streaks inside {[2:4]}; }

  `uvm_object_utils(store_streak_vseq)

  function new(string name = "store_streak_vseq");
    super.new(name);
    region_lo = 32'h0000_0000;
    region_hi = addr_t'(4 * LINE_BYTES - 1);
  endfunction

  virtual task run_core_seq(int unsigned c);
    core_store_streak_seq s;
    repeat (n_streaks) begin
      s = core_store_streak_seq::type_id::create($sformatf("core%0d_streak", c));
      s.region_lo = region_lo;
      s.region_hi = region_hi;
      if (!s.randomize())
        `uvm_error(get_type_name(), "core_store_streak_seq randomize failed")
      s.start(p_sequencer.core_sqr[c]);
    end
  endtask

endclass


// Message passing litmus test. Core 0 publishes a payload then sets a flag on a
// different line; core 1 spins on the flag and must then observe the payload.
// With blocking caches on an atomic bus the model is sequentially consistent,
// so the payload can never be stale.
class producer_consumer_vseq extends cache_base_vseq;

  rand int unsigned n_msgs;
  addr_t            data_addr;
  addr_t            flag_addr;

  constraint c_msgs { n_msgs inside {[4:12]}; }

  `uvm_object_utils(producer_consumer_vseq)

  function new(string name = "producer_consumer_vseq");
    super.new(name);
  endfunction

  static function data_t payload_of(int unsigned k);
    return 32'hc0de_0000 + k;
  endfunction

  virtual task body();
    if (NUM_CORES != 2) begin
      `uvm_warning(get_type_name(), "litmus sequence assumes exactly two cores")
      return;
    end

    data_addr = region_lo;
    flag_addr = region_lo + addr_t'(LINE_BYTES);

    // Unwritten memory returns a hash of its address, not zero, so the flag has
    // to be seeded below the first message index before the consumer polls it.
    begin
      core_single_seq s;
      s = core_single_seq::type_id::create("flag_init");
      if (!s.randomize() with { op == CORE_STORE; addr == flag_addr; wdata == '0; be == '1; })
        `uvm_error(get_type_name(), "flag init randomize failed")
      s.start(p_sequencer.core_sqr[0]);
    end

    fork
      producer();
      consumer();
    join
  endtask

  task producer();
    core_single_seq s;
    data_t          pl;
    data_t          fv;

    for (int unsigned k = 1; k <= n_msgs; k++) begin
      pl = payload_of(k);
      fv = data_t'(k);

      s = core_single_seq::type_id::create("prod_data");
      if (!s.randomize() with { op == CORE_STORE; addr == data_addr; wdata == pl; })
        `uvm_error(get_type_name(), "producer data randomize failed")
      s.start(p_sequencer.core_sqr[0]);

      s = core_single_seq::type_id::create("prod_flag");
      if (!s.randomize() with { op == CORE_STORE; addr == flag_addr; wdata == fv; })
        `uvm_error(get_type_name(), "producer flag randomize failed")
      s.start(p_sequencer.core_sqr[0]);
    end
  endtask

  task consumer();
    core_single_seq s;
    int unsigned    polls;
    data_t          seen_flag;

    for (int unsigned k = 1; k <= n_msgs; k++) begin
      polls     = 0;
      seen_flag = 0;

      while (seen_flag < k && polls < 400) begin
        s = core_single_seq::type_id::create("cons_flag");
        if (!s.randomize() with { op == CORE_LOAD; addr == flag_addr; })
          `uvm_error(get_type_name(), "consumer flag randomize failed")
        s.start(p_sequencer.core_sqr[1]);
        seen_flag = s.observed_rdata;
        polls++;
      end

      if (seen_flag < k) begin
        `uvm_error(get_type_name(),
          $sformatf("flag %0d never observed after %0d polls", k, polls))
        return;
      end

      s = core_single_seq::type_id::create("cons_data");
      if (!s.randomize() with { op == CORE_LOAD; addr == data_addr; pre_delay == 0; })
        `uvm_error(get_type_name(), "consumer data randomize failed")
      s.start(p_sequencer.core_sqr[1]);

      // The producer runs concurrently, when this load completes the
      // payload may be newer than the flag we observed. The
      // ordering property is that it can never be older. 
      if (s.observed_rdata[31:16] !== 16'hc0de ||
          s.observed_rdata[15:0]   <  seen_flag[15:0])
        `uvm_error(get_type_name(),
          $sformatf("message passing violated: flag=%0d but payload=0x%08h is stale",
                    seen_flag, s.observed_rdata))
    end
  endtask

endclass


// Fully directed walk of every legal same-line MESI transition, in a known
// order, on a cache that starts empty. Each access is issued and completed
// before the next begins, so the resulting transition sequence is deterministic
// rather than a property of the seed.

class mesi_walk_vseq extends cache_base_vseq;

  `uvm_object_utils(mesi_walk_vseq)

  function new(string name = "mesi_walk_vseq");
    super.new(name);
  endfunction

  virtual task body();
    addr_t l0, l1, l2;

    if (NUM_CORES != 2) begin
      `uvm_warning(get_type_name(), "directed walk assumes exactly two cores")
      return;
    end

    l0 = region_lo;
    l1 = region_lo + addr_t'(LINE_BYTES);
    l2 = region_lo + addr_t'(2 * LINE_BYTES);

    // c0: I->E    nobody holds the line, ReadShared returns !IsShared
    do_access(0, CORE_LOAD,  l0, '0);
    // c0: E->M    silent upgrade, no bus transaction at all
    do_access(0, CORE_STORE, l0, 32'h1111_0001);
    // c0: M->S and c1: I->S    snoop ReadShared, PassDirty, memory refreshed
    do_access(1, CORE_LOAD,  l0, '0);
    // c0: S->M and c1: S->I    CleanUnique, no data movement
    do_access(0, CORE_STORE, l0, 32'h1111_0002);
    // c0: M->I and c1: I->M    ReadUnique with dirty intervention
    do_access(1, CORE_STORE, l0, 32'h1111_0003);

    // c0: I->E then E->S on a remote read
    do_access(0, CORE_LOAD,  l1, '0);
    do_access(1, CORE_LOAD,  l1, '0);
    // c1: S->M and c0: S->I
    do_access(1, CORE_STORE, l1, 32'h2222_0001);

    // c0: I->E then E->I on a remote write
    do_access(0, CORE_LOAD,  l2, '0);
    do_access(1, CORE_STORE, l2, 32'h3333_0001);

    `uvm_info(get_type_name(),
              "walked I->E E->M M->S I->S S->M S->I M->I E->S E->I I->M", UVM_LOW)
  endtask

endclass

// Both caches are driven into S on the same line, then both issue a store at
// the same time. One wins arbitration and completes a CleanUnique, invalidating
// the other. The loser is already parked in ST_BUS with a CleanUnique pending
// that is now wrong, and must re-derive it as a ReadUnique at grant.
//
// This cannot be forced with absolute certainty from the core interfaces (it
// depends on both caches being in ST_BUS together) but a bus transaction is
// tens of cycles long and the stores are issued with zero delay, so the overlap
// is reliable.
class upgrade_race_vseq extends cache_base_vseq;

  rand int unsigned n_rounds;

  constraint c_rounds { n_rounds inside {[4:8]}; }

  `uvm_object_utils(upgrade_race_vseq)

  function new(string name = "upgrade_race_vseq");
    super.new(name);
  endfunction

  virtual task body();
    addr_t x;

    if (NUM_CORES != 2) begin
      `uvm_warning(get_type_name(), "upgrade race assumes exactly two cores")
      return;
    end

    for (int unsigned r = 0; r < n_rounds; r++) begin
      x = region_lo + addr_t'(r * LINE_BYTES);

      // Both caches into S.
      do_access(0, CORE_LOAD, x, '0);
      do_access(1, CORE_LOAD, x, '0);

      // Both want write permission at once.
      fork
        do_access(0, CORE_STORE, x, 32'haaaa_0000 + r);
        do_access(1, CORE_STORE, x, 32'hbbbb_0000 + r);
      join
    end
  endtask

endclass


// Randomly chains several of the above so a single seed covers many phases.
class mixed_vseq extends cache_base_vseq;

  rand int unsigned n_phases;

  constraint c_phases { n_phases inside {[3:6]}; }

  `uvm_object_utils(mixed_vseq)

  function new(string name = "mixed_vseq");
    super.new(name);
  endfunction

  virtual task body();
    cache_base_vseq v;
    int unsigned    sel;

    for (int unsigned p = 0; p < n_phases; p++) begin
      sel = $urandom_range(6, 0);
      case (sel)
        0: v = random_vseq::type_id::create("ph_random");
        1: v = shared_region_vseq::type_id::create("ph_shared");
        2: v = false_sharing_vseq::type_id::create("ph_false");
        3: v = pingpong_vseq::type_id::create("ph_pingpong");
        4: v = eviction_vseq::type_id::create("ph_evict");
        5: v = store_streak_vseq::type_id::create("ph_streak");
        default: v = read_mostly_vseq::type_id::create("ph_read");
      endcase
      if (!v.randomize() with { num_txns inside {[15:35]}; })
        `uvm_error(get_type_name(), "phase randomize failed")
      v.start(p_sequencer);
    end
  endtask

endclass

`endif

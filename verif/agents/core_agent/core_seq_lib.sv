`ifndef CORE_SEQ_LIB_SV
`define CORE_SEQ_LIB_SV

// Random ops inside a configurable address window. Every other sequence in this
// file narrows that window or fixes the address to target a specific coherence
// behaviour; they all reuse this randomisation and delay model.
class core_base_seq extends uvm_sequence #(core_item);

  rand int unsigned num_txns;
  rand int unsigned store_pct;

  addr_t region_lo = 32'h0000_0000;
  addr_t region_hi = 32'h0000_0fff;

  constraint c_num_txns  { soft num_txns inside {[30:80]}; num_txns > 0; }
  constraint c_store_pct { soft store_pct inside {[20:80]}; store_pct <= 100; }

  `uvm_object_utils(core_base_seq)

  function new(string name = "core_base_seq");
    super.new(name);
  endfunction

  virtual task body();
    repeat (num_txns) send_one();
  endtask

  virtual task send_one();
    core_item it;
    it = core_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with {
          addr inside {[region_lo : region_hi]};
          op dist { CORE_STORE := store_pct, CORE_LOAD := (100 - store_pct) };
        })
      `uvm_error(get_type_name(), "core_item randomize failed")
    finish_item(it);
  endtask

endclass


// All traffic confined to one line. With both cores running this, distinct
// words of the same line produce false sharing.
class core_line_seq extends core_base_seq;

  rand addr_t line_base;

  constraint c_line {
    line_base[OFFSET_W-1:0] == '0;
    line_base inside {[region_lo : region_hi]};
  }

  `uvm_object_utils(core_line_seq)

  function new(string name = "core_line_seq");
    super.new(name);
  endfunction

  virtual task send_one();
    core_item it;
    it = core_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with {
          addr inside {[line_base : line_base + LINE_BYTES - 1]};
          op dist { CORE_STORE := store_pct, CORE_LOAD := (100 - store_pct) };
        })
      `uvm_error(get_type_name(), "core_item randomize failed")
    finish_item(it);
  endtask

endclass


// Single address hammered by both cores: migratory sharing, M ping-pong.
class core_pingpong_seq extends core_base_seq;

  rand addr_t target;

  constraint c_target {
    target[BYTE_OFF_W-1:0] == '0;
    target inside {[region_lo : region_hi]};
  }
  constraint c_mix { soft store_pct inside {[40:60]}; }

  `uvm_object_utils(core_pingpong_seq)

  function new(string name = "core_pingpong_seq");
    super.new(name);
  endfunction

  virtual task send_one();
    core_item it;
    it = core_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with {
          addr == target;
          op dist { CORE_STORE := store_pct, CORE_LOAD := (100 - store_pct) };
        })
      `uvm_error(get_type_name(), "core_item randomize failed")
    finish_item(it);
  endtask
endclass


// More live tags than ways in a single set, so every miss forces a victim and
// dirty victims force writebacks.
class core_set_conflict_seq extends core_base_seq;

  rand index_t      target_set;
  rand int unsigned num_tags;

  constraint c_tags { num_tags inside {[NUM_WAYS + 1 : NUM_WAYS + 4]}; }

  `uvm_object_utils(core_set_conflict_seq)

  function new(string name = "core_set_conflict_seq");
    super.new(name);
  endfunction

  virtual task send_one();
    core_item    it;
    int unsigned k;
    addr_t       base;

    k    = $urandom_range(num_tags - 1, 0);
    base = make_addr(tag_t'(k), target_set);

    it = core_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with {
          addr inside {[base : base + LINE_BYTES - 1]};
          op dist { CORE_STORE := store_pct, CORE_LOAD := (100 - store_pct) };
        })
      `uvm_error(get_type_name(), "core_item randomize failed")
    finish_item(it);
  endtask

endclass

// Repeated stores to one address: exercises the silent E->M upgrade and long
// runs of M hits that generate no bus traffic at all.
class core_store_streak_seq extends core_base_seq;

  rand addr_t target;

  constraint c_target { target[BYTE_OFF_W-1:0] == '0; target inside {[region_lo : region_hi]}; }
  constraint c_all_st { store_pct == 100; }
  constraint c_short  { soft num_txns inside {[8:20]}; }

  `uvm_object_utils(core_store_streak_seq)

  function new(string name = "core_store_streak_seq");
    super.new(name);
  endfunction

  virtual task send_one();
    core_item it;
    it = core_item::type_id::create("it");
    start_item(it);
    if (!it.randomize() with { addr == target; op == CORE_STORE; pre_delay == 0; })
      `uvm_error(get_type_name(), "core_item randomize failed")
    finish_item(it);
  endtask

endclass

// Loads only, so lines settle into S/E and stay there.
class core_read_only_seq extends core_base_seq;
  constraint c_no_stores { store_pct == 0; }
  `uvm_object_utils(core_read_only_seq)
  function new(string name = "core_read_only_seq");
    super.new(name);
  endfunction
endclass

// Single explicit access, for directed litmus sequences.
class core_single_seq extends uvm_sequence #(core_item);

  rand core_op_e    op;
  rand addr_t       addr;
  rand data_t       wdata;
  rand strb_t       be;
  rand int unsigned pre_delay;

  data_t observed_rdata;

  constraint c_defaults { be == '1; soft pre_delay inside {[0:3]}; }

  `uvm_object_utils(core_single_seq)

  function new(string name = "core_single_seq");
    super.new(name);
  endfunction

  virtual task body();
    core_item it;
    it = core_item::type_id::create("it");
    start_item(it);
    it.op        = op;
    it.addr      = addr;
    it.wdata     = wdata;
    it.be        = be;
    it.pre_delay = pre_delay;
    finish_item(it);
    observed_rdata = it.rdata;
  endtask

endclass

`endif

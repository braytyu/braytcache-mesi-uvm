`ifndef CACHE_SVA_SV
`define CACHE_SVA_SV

`timescale 1ns/1ps

// Bound into every l1_cache instance. Checks the core-side handshake and the atomic-bus assumptions.
module cache_sva import cache_pkg::*; (
  input logic    clk,
  input logic    rst_n,
  input logic    core_req,
  input logic    core_gnt,
  input logic    core_rvalid,
  input addr_t   core_addr,
  input logic    core_we,
  input strb_t   core_be,
  input data_t   core_wdata,
  input logic    bus_req,
  input logic    bus_gnt,
  input bus_op_e bus_op,
  input logic    bus_rsp_valid,
  input logic    snoop_valid,
  input logic    snoop_sel,
  input bus_op_e snoop_op,
  input logic    snoop_ack,
  input logic    snoop_hit,
  input logic    snoop_pass_dirty
);

  default clocking sva_cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // Tracks accepted-but-unanswered core requests, so a response can be checked
  // against something rather than just assumed to be solicited.
  int outstanding;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) outstanding <= 0;
    else        outstanding <= outstanding + ((core_req && core_gnt) ? 1 : 0)
                                           - (core_rvalid ? 1 : 0);
  end

  // --- core handshake -----------------------------------------------------

  a_core_req_stable: assert property (
    core_req && !core_gnt |=> core_req);

  a_core_payload_stable: assert property (
    core_req && !core_gnt |=> $stable(core_addr) && $stable(core_we) &&
                              $stable(core_be)   && $stable(core_wdata));

  a_core_addr_aligned: assert property (
    core_req |-> core_addr[BYTE_OFF_W-1:0] == '0);

  a_core_be_nonzero: assert property (
    core_req && core_we |-> core_be != '0);

  a_no_spurious_rvalid: assert property (
    core_rvalid |-> outstanding > 0);

  a_single_outstanding: assert property (
    outstanding inside {0, 1});

  // --- coherent bus assumptions -------------------------------------------

  // The whole no-transient-state argument rests on this.
  a_grant_excludes_snoop: assert property (
    bus_gnt |-> !(snoop_valid && snoop_sel));

  a_snoop_ack_qualified: assert property (
    snoop_ack |-> snoop_valid && snoop_sel);

  a_snoop_pd_implies_hit: assert property (
    snoop_ack && snoop_pass_dirty |-> snoop_hit);

  a_no_pass_dirty_on_upgrade: assert property (
    snoop_ack && snoop_op == BUS_CLEAN_UNIQUE |-> !snoop_pass_dirty);

  a_rsp_needs_grant: assert property (
    bus_rsp_valid |-> bus_gnt);

  // The cache re-derives its bus op combinationally every cycle. Once granted
  // that choice must be frozen, because a granted cache is never snooped.
  a_op_frozen_while_granted: assert property (
    bus_gnt ##1 bus_gnt |-> $stable(bus_op));

  // A request may be withdrawn if an intervening snoop removes the need for
  // it; what must not happen is a request that neither completes nor retires.
  a_bus_progress: assert property (
    bus_req && !bus_gnt |-> ##[1:500] (bus_gnt || !bus_req));

endmodule

`endif

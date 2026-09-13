`ifndef BUS_IF_SV
`define BUS_IF_SV

`timescale 1ns/1ps

// Simplified ACE coherent bus. Atomic: the interconnect grants one master at a
// time and the transaction (snoop + optional memory access + response)
// completes before the next grant, so caches never enter transient states.
//
// Per-master fields are unpacked arrays so each cache drives only its own
// element, avoids multiple drivers on a shared packed vector. For the same
// reason this interface carries no modports; monitors read signals directly
// after the clock edge.
interface bus_if (input logic clk, input logic rst_n);
  import cache_pkg::*;

  // Request phase, driven by each cache on its own index.
  logic    req   [NUM_CORES];
  bus_op_e op    [NUM_CORES];
  addr_t   addr  [NUM_CORES];
  line_t   wdata [NUM_CORES];

  // Grant and completion, driven by the interconnect.
  logic  gnt       [NUM_CORES];
  logic  rsp_valid [NUM_CORES];
  logic  rsp_shared;
  line_t rsp_data;

  // Snoop broadcast, driven by the interconnect.
  logic    snoop_valid;
  bus_op_e snoop_op;
  addr_t   snoop_addr;
  logic    snoop_sel [NUM_CORES];

  // Snoop response, driven by each snooping cache on its own index.
  logic  snoop_ack        [NUM_CORES];
  logic  snoop_hit        [NUM_CORES];
  logic  snoop_pass_dirty [NUM_CORES];
  line_t snoop_data       [NUM_CORES];

endinterface

`endif

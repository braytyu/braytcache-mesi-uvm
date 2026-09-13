`ifndef CACHE_VSEQUENCER_SV
`define CACHE_VSEQUENCER_SV

// Holds a handle to every core sequencer so a virtual sequence can coordinate traffic across both caches.
class cache_vsequencer extends uvm_sequencer;

  core_sequencer core_sqr [NUM_CORES];

  `uvm_component_utils(cache_vsequencer)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass

`endif

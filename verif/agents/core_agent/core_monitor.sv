`ifndef CORE_MONITOR_SV
`define CORE_MONITOR_SV

class core_monitor extends uvm_monitor;

  virtual core_if vif;
  core_agent_cfg  cfg;

  uvm_analysis_port #(core_item) ap;

  `uvm_component_utils(core_monitor)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  // Address phase and response phase are separate events, so accepted requests
  // are queued and completed when rvalid arrives. The item is published only on
  // completion, and the scoreboard orders transactions by when they retire.
  task run_phase(uvm_phase phase);
    core_item pend[$];
    core_item it;

    forever begin
      @(vif.mon_cb);

      if (vif.rst_n !== 1'b1) begin
        pend.delete();
        continue;
      end

      if (vif.mon_cb.req === 1'b1 && vif.mon_cb.gnt === 1'b1) begin
        it            = core_item::type_id::create("it");
        it.op         = (vif.mon_cb.we === 1'b1) ? CORE_STORE : CORE_LOAD;
        it.addr       = vif.mon_cb.addr;
        it.be         = vif.mon_cb.be;
        it.wdata      = vif.mon_cb.wdata;
        it.core_id    = cfg.core_id;
        it.start_time = $time;
        pend.push_back(it);
      end

      if (vif.mon_cb.rvalid === 1'b1) begin
        if (pend.size() == 0) begin
          `uvm_error("CORE_MON", "rvalid with no outstanding request")
        end else begin
          it          = pend.pop_front();
          it.rdata    = vif.mon_cb.rdata;
          it.end_time = $time;
          ap.write(it);
        end
      end
    end
  endtask

endclass

`endif

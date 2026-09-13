`ifndef BUS_MONITOR_SV
`define BUS_MONITOR_SV

// Passive observer of the coherent bus. Signals are read immediately after the
// clock edge, which yields pre-edge values.
class bus_monitor extends uvm_monitor;

  virtual bus_if vif;

  uvm_analysis_port #(bus_item) ap;

  `uvm_component_utils(bus_monitor)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  // Follows one coherent transaction at a time: latch op and address at grant,
  // accumulate snoop results during the snoop phase, publish at completion.
  task run_phase(uvm_phase phase);
    bus_item     it;
    int unsigned cur;
    bit          active;

    active = 1'b0;
    it     = null;

    forever begin
      @(posedge vif.clk);

      if (vif.rst_n !== 1'b1) begin
        active = 1'b0;
        it     = null;
        continue;
      end

      if (!active) begin
        for (int unsigned i = 0; i < NUM_CORES; i++) begin
          if (!active && vif.gnt[i] === 1'b1) begin
            active       = 1'b1;
            cur          = i;
            it           = bus_item::type_id::create("it");
            it.core_id   = i;
            it.op        = vif.op[i];
            it.addr      = line_addr(vif.addr[i]);
            it.snoop_hit = '0;
            it.snoop_pd  = '0;
            it.t_start   = $time;
          end
        end
      end

      if (active) begin
        if (vif.snoop_valid === 1'b1) begin
          for (int unsigned i = 0; i < NUM_CORES; i++) begin
            if (vif.snoop_sel[i] === 1'b1 && vif.snoop_ack[i] === 1'b1) begin
              it.snoop_hit[i] = vif.snoop_hit[i];
              it.snoop_pd[i]  = vif.snoop_pass_dirty[i];
            end
          end
        end

        if (vif.rsp_valid[cur] === 1'b1) begin
          it.shared = vif.rsp_shared;
          it.data   = vif.rsp_data;
          it.t_end  = $time;
          ap.write(it);
          active = 1'b0;
          it     = null;
        end
      end
    end
  endtask

endclass

`endif

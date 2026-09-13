`ifndef AXIL_MONITOR_SV
`define AXIL_MONITOR_SV

class axil_monitor extends uvm_monitor;

  // Passive reconstruction of AXI4-Lite transactions. Feeds coverage only.
  // The scoreboard reads the memory model directly at end of test.
  virtual axil_if vif;
  axil_agent_cfg  cfg;

  uvm_analysis_port #(axil_item) ap;

  `uvm_component_utils(axil_monitor)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    fork
      mon_write();
      mon_read();
    join
  endtask

  task mon_write();
    axil_item it;
    addr_t    a;
    data_t    d;
    strb_t    s;
    bit       got_aw;
    bit       got_w;

    got_aw = 1'b0;
    got_w  = 1'b0;

    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        got_aw = 1'b0;
        got_w  = 1'b0;
        continue;
      end

      if (vif.mon_cb.awvalid === 1'b1 && vif.mon_cb.awready === 1'b1) begin
        a      = vif.mon_cb.awaddr;
        got_aw = 1'b1;
      end
      if (vif.mon_cb.wvalid === 1'b1 && vif.mon_cb.wready === 1'b1) begin
        d      = vif.mon_cb.wdata;
        s      = vif.mon_cb.wstrb;
        got_w  = 1'b1;
      end
      if (vif.mon_cb.bvalid === 1'b1 && vif.mon_cb.bready === 1'b1) begin
        if (!(got_aw && got_w)) begin
          `uvm_error("AXIL_MON", "write response before address and data phases")
        end else begin
          it          = axil_item::type_id::create("it");
          it.is_write = 1'b1;
          it.addr     = a;
          it.data     = d;
          it.strb     = s;
          it.resp     = vif.mon_cb.bresp;
          ap.write(it);
        end
        got_aw = 1'b0;
        got_w  = 1'b0;
      end
    end
  endtask

  task mon_read();
    axil_item it;
    addr_t    a;
    bit       got_ar;

    got_ar = 1'b0;

    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) begin
        got_ar = 1'b0;
        continue;
      end

      if (vif.mon_cb.arvalid === 1'b1 && vif.mon_cb.arready === 1'b1) begin
        a      = vif.mon_cb.araddr;
        got_ar = 1'b1;
      end
      if (vif.mon_cb.rvalid === 1'b1 && vif.mon_cb.rready === 1'b1) begin
        if (!got_ar) begin
          `uvm_error("AXIL_MON", "read data before address phase")
        end else begin
          it          = axil_item::type_id::create("it");
          it.is_write = 1'b0;
          it.addr     = a;
          it.data     = vif.mon_cb.rdata;
          it.strb     = '1;
          it.resp     = vif.mon_cb.rresp;
          ap.write(it);
        end
        got_ar = 1'b0;
      end
    end
  endtask

endclass

`endif

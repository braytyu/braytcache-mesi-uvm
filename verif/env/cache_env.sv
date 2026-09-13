`ifndef CACHE_ENV_SV
`define CACHE_ENV_SV

class cache_env extends uvm_env;

  cache_env_cfg        cfg;
  core_agent           core_agt  [NUM_CORES];
  probe_monitor        probe_mon [NUM_CORES];
  axil_agent           axil_agt;
  bus_monitor          bus_mon;
  coherence_scoreboard sb;
  cache_coverage       cov;
  cache_vsequencer     vsqr;

  `uvm_component_utils(cache_env)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Per-core agents and probes are built from the geometry.
  function void build_phase(uvm_phase phase);
    string agt_name;
    super.build_phase(phase);

    if (!uvm_config_db #(cache_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CACHE_ENV", "cache_env_cfg not found in config_db")

    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      agt_name = $sformatf("core_agt%0d", i);
      uvm_config_db #(core_agent_cfg)::set(this, agt_name, "cfg", cfg.core_cfg[i]);
      core_agt[i]  = core_agent::type_id::create(agt_name, this);
      probe_mon[i] = probe_monitor::type_id::create($sformatf("probe_mon%0d", i), this);
    end

    uvm_config_db #(axil_agent_cfg)::set(this, "axil_agt", "cfg", cfg.axil_cfg);
    axil_agt = axil_agent::type_id::create("axil_agt", this);

    bus_mon = bus_monitor::type_id::create("bus_mon", this);
    vsqr    = cache_vsequencer::type_id::create("vsqr", this);

    if (cfg.scoreboard_en) sb  = coherence_scoreboard::type_id::create("sb", this);
    if (cfg.coverage_en)   cov = cache_coverage::type_id::create("cov", this);
  endfunction

  // Every observation stream fans out to both the scoreboard and coverage. The
  // probe virtual interfaces are handed over directly as well, because the SWMR
  // sweep needs a whole-cache snapshot.
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);

    bus_mon.vif = cfg.bus_vif;

    for (int unsigned i = 0; i < NUM_CORES; i++) begin
      probe_mon[i].vif     = cfg.probe_vif[i];
      probe_mon[i].core_id = i;
      vsqr.core_sqr[i]     = core_agt[i].sqr;
    end

    if (sb != null) begin
      sb.mem = cfg.mem;
      for (int unsigned i = 0; i < NUM_CORES; i++) begin
        sb.probe_vif[i] = cfg.probe_vif[i];
        core_agt[i].ap.connect(sb.core_imp);
        probe_mon[i].ap.connect(sb.probe_imp);
      end
      bus_mon.ap.connect(sb.bus_imp);
    end

    if (cov != null) begin
      for (int unsigned i = 0; i < NUM_CORES; i++) begin
        cov.probe_vif[i] = cfg.probe_vif[i];
        core_agt[i].ap.connect(cov.core_imp);
        probe_mon[i].ap.connect(cov.probe_imp);
      end
      bus_mon.ap.connect(cov.bus_imp);
      axil_agt.ap.connect(cov.axil_imp);
    end
  endfunction

endclass

`endif

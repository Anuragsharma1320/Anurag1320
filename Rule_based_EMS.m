close all; clear; clc;

%% ---------- Load Data ----------
.xlsx file from SMARD German Market real -time forecasted data

%% ---------- Buy/Sell Tariffs ----------
Price_buy  = Price;
Price_sell = 0.60 * Price;

%% ---------- Parameters ----------
n  = 24; dt = 1;

% BESS
BESS_capacity = 48;               
SOCmin_BESS   = 0.20 * BESS_capacity;   
SOCmax_BESS   = 0.90 * BESS_capacity;
P_bess_max    = 20;               
eta_b_ch      = 0.90;
eta_b_dis     = 0.90;

% EV
EV_capacity = 40;                 
SOCmax_EV   = 0.95 * EV_capacity; % upper physical cap
EV_P_max    = 18;                 
eta_ev_ch   = 0.95;
eta_ev_dis  = 0.95;

% Initial SoCs
SOCpct_BESS_0 = 50;   % %
SOCpct_EV_0   = 80;   % % (start "range-ready")

%% ---------- EV availability ----------
% Charge allowed: 00–07, 11–16, and (recommended) late top-up 21–23
charge_hours    = [0 1 2 3 4 5 6 7 11 12 13 14 15 16 21 22 23];
% Discharge allowed: 18–22
discharge_hours = [18 19 20 21 22];
a_ch  = ismember(0:n-1, charge_hours)';     
a_dis = ismember(0:n-1, discharge_hours)';  

%% ---------- Dynamic EV SoC policy ----------
% Base floor for V2G participation (driver reserve)
EV_SOC_min_base  = 0.60 * EV_capacity;  % 60% base
% Ready hours when SoC must be ≥80% (e.g., morning commute 07–08)
ev_ready_hours   = [7 8];               % 0..23
EV_SOC_min_curve = EV_SOC_min_base * ones(n,1);
EV_SOC_min_curve(ismember((0:n-1)', ev_ready_hours)) = 0.80 * EV_capacity;

% Final-day target (exact equality via final correction step)
EV_final_target = 0.80 * EV_capacity;   % 80%

%% ---------- Init (Pseudo code) ----------
E_BESS = (SOCpct_BESS_0/100)*BESS_capacity;
E_EV   = (SOCpct_EV_0/100)*EV_capacity;

SOCpct_BESS = zeros(n+1,1); SOCpct_BESS(1) = SOCpct_BESS_0;
SOCpct_EV   = zeros(n+1,1); SOCpct_EV(1)   = SOCpct_EV_0;

P_BESS = zeros(n,1);    
P_EV   = zeros(n,1);    
Pgrid  = zeros(n,1);    

total_gen     = zeros(n,1);
power_balance = zeros(n,1);

eps_price = 0.005; % €/kWh

FOR each timestep t:
    Compute residual = (PV + Wind + Biogas - Load)

    IF price_now < future_min_price:
        Desire = "Charge"
    ELSE IF price_now > future_max_price:
        Desire = "Discharge"
    ELSE:
        Desire = "Hold"
    END IF

    Enforce SOC limits (BESS, EV)
    Apply EV ready-hour constraint

    Allocate desired power proportionally:
        BESS share ∝ available capacity
        EV share   ∝ available capacity

    Update SOCs
    Compute grid import/export
END FOR


%% ---------- Final SoC correction ----------
final soc = initial soc


%% ---------- KPIs ----------
E_import   = sum(max(Pgrid,0))*dt;
E_export   = sum(max(-Pgrid,0))*dt;
cost_import = sum(max(Pgrid,0).*Price_buy)*dt;
rev_export  = sum(max(-Pgrid,0).*Price_sell)*dt;
net_cost    = cost_import - rev_export;

E_bess_ch  = sum(max(P_BESS,0))*dt;
E_bess_dis = sum(max(-P_BESS,0))*dt;
E_ev_ch    = sum(max(P_EV,0))*dt;
E_ev_dis   = sum(max(-P_EV,0))*dt;

cycles_BESS = min(E_bess_ch, E_bess_dis)/BESS_capacity;
cycles_EV   = min(E_ev_ch,   E_ev_dis)/EV_capacity;

peak_import = max(max(Pgrid,0));
peak_export = max(max(-Pgrid,0));

E_load = sum(Load)*dt;
gen_total = PV + Wind + Biogas;
self_sufficiency  = max(0, 1 - E_import/max(1e-9,E_load));
ren_share_of_load = sum(min(gen_total, Load))*dt / max(1e-9, E_load);

fprintf('\n--- KPIs (Rule-based; dynamic EV min + EV final 80%%) ---\n');
fprintf('Import cost (€):  %.2f   | Export revenue (€): %.2f   | Net (€): %.2f\n', ...
        cost_import, rev_export, net_cost);
fprintf('Grid energy (kWh): Import %.1f  | Export %.1f\n', E_import, E_export);
fprintf('BESS ch/dis (kWh): %.1f / %.1f   | cycles ≈ %.2f\n', E_bess_ch, E_bess_dis, cycles_BESS);
fprintf('EV   ch/dis (kWh): %.1f / %.1f   | cycles ≈ %.2f\n', E_ev_ch, E_ev_dis, cycles_EV);
fprintf('Peaks (kW): Import %.1f  | Export %.1f\n', peak_import, peak_export);
fprintf('Self-sufficiency: %.1f%%  | Renewable-share (rough): %.1f%%\n', ...
        100*self_sufficiency, 100*ren_share_of_load);
fprintf('Final SoC end: BESS %.1f%% | EV %.1f%% (target EV 80%%)\n', SOCpct_BESS(end), SOCpct_EV(end));



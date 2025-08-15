%% ---------- Load Data ----------
data  = readtable('MG-data-0.xlsx');
PV     = data.PV(:);
Wind   = data.Wind(:);
Biogas = data.Biogas(:);
Load   = data.Demand(:);
Price  = data.Price(:);      % base price profile (€/kWh)

%% ---------- Buy/Sell Tariffs (grid only) ----------
Price_buy  = Price;           % import price (€/kWh)
Price_sell = 0.60 * Price;    % export price (€/kWh): sell < buy

%% ---------- Parameters ----------
n  = 24;      % Time horizon (hours 0..23)
dt = 1;       % hour step

% BESS
BESS_capacity = 48;           % kWh
SOC_min       = 0.20 * BESS_capacity;
SOC_max       = 0.90 * BESS_capacity;
eta_ch        = 0.90;
eta_dis       = 0.90;
P_bess_max    = 20;           % kW

% EV
EV_capacity = 40;                  % kWh
EV_SOC_max  = 0.95 * EV_capacity;  % 95%
EV_P_max    = 18;                  % kW
eta_ev_ch   = 0.95;
eta_ev_dis  = 0.95;

% Initial SoCs
E0_BESS = 0.50 * BESS_capacity;
E0_EV   = 0.80 * EV_capacity;      % start at 80% for good range

%% ---------- EV availability (you set these) ----------
% Charge allowed: overnight 00–08 and midday 11–16
charge_hours    = [0 1 2 3 4 5 6 7 11 12 13 14 15 16 ];
% Discharge allowed: evening peak 18–22
discharge_hours = [18 19 20 21 22];

a_ch  = ismember((0:n-1), charge_hours)';     % n×1 (0/1)
a_dis = ismember((0:n-1), discharge_hours)';  % n×1 (0/1)

%% ---------- Dynamic EV SoC policy ----------
% Base floor for V2G participation (driver reserve)
EV_SOC_min_base = 0.60 * EV_capacity;   % 60% base
% “Ready hours” when car must be ≥80% (0..23). Example: morning 07–08.
ev_ready_hours = [8 9 10];

EV_SOC_min_curve = EV_SOC_min_base * ones(n,1);
EV_SOC_min_curve(ismember((0:n-1)', ev_ready_hours)) = 0.80 * EV_capacity;

%% ---------- Decision vector ----------
% [ P_grid_buy(1..n);
%   P_grid_sell(1..n);
%   P_bess_ch(1..n);
%   P_bess_dis(1..n);
%   SOC_BESS(1..n);
%   P_ev_ch(1..n);
%   P_ev_dis(1..n);
%   SOC_EV(1..n);
%   u_ev_ch(1..n);        % binary
%   u_ev_dis(1..n) ]      % binary
num_vars = 10*n;

%% ---------- Objective (grid-only cost) ----------
f = [ Price_buy;          % + cost on grid import
     -Price_sell;         % - revenue on grid export
      zeros(3*n,1);       % BESS ch/dis + SOC_BESS
      zeros(n,1);         % EV charge
      zeros(n,1);         % EV discharge
      zeros(n,1);         % SOC_EV
      zeros(2*n,1) ];     % binaries

%% ---------- Equality constraints ----------
% Rows: power balance (n) + BESS SOC dyn (n-1) + EV SOC dyn (n-1)
%     + 2 initial SOC + 1 final BESS equality
Aeq = zeros(n + (n-1) + (n-1) + 2, num_vars);
beq = zeros(size(Aeq,1), 1);
row = 0;

% Power balance at PCC:
for t = 1:n
    row = row + 1;
    Aeq(row, t)       =  1;        % + P_grid_buy
    Aeq(row, n + t)   = -1;        % - P_grid_sell
    Aeq(row, 2*n + t) = -1;        % - P_bess_ch
    Aeq(row, 3*n + t) =  1;        % + P_bess_dis
    Aeq(row, 5*n + t) = -1;        % - P_ev_ch
    Aeq(row, 6*n + t) =  1;        % + P_ev_dis
    beq(row) = Load(t) - PV(t) - Wind(t) - Biogas(t);
end

% ----- BESS SOC dynamics (correct signs) -----
for t = 1:n-1
    row = row + 1;
    Aeq(row, 4*n + t)     = -1;                 % -SOC_BESS(t)
    Aeq(row, 4*n + t + 1) =  1;                 % +SOC_BESS(t+1)
    Aeq(row, 2*n + t)     = -eta_ch * dt;       % -η_ch * P_bess_ch
    Aeq(row, 3*n + t)     =  (1/eta_dis) * dt;  % +1/η_dis * P_bess_dis
end

% ----- EV SOC dynamics (correct signs) -----
for t = 1:n-1
    row = row + 1;
    Aeq(row, 7*n + t)     = -1;                      % -SOC_EV(t)
    Aeq(row, 7*n + t + 1) =  1;                      % +SOC_EV(t+1)
    Aeq(row, 5*n + t)     = -eta_ev_ch * dt;         % -η_ev_ch * P_ev_ch
    Aeq(row, 6*n + t)     =  (1/eta_ev_dis) * dt;    % +1/η_ev_dis * P_ev_dis
end

% Initial SOCs
row = row + 1;  Aeq(row, 4*n + 1) = 1;  beq(row) = E0_BESS;
row = row + 1;  Aeq(row, 7*n + 1) = 1;  beq(row) = E0_EV;

%% ---------- Inequality constraints (A*x <= b) ----------
A = []; b = [];

% Convenience indices
idx_P_ev_ch  = 5*n + (1:n);
idx_P_ev_dis = 6*n + (1:n);
idx_u_ch     = 8*n + (1:n);
idx_u_dis    = 9*n + (1:n);

% Gate EV power by binaries
A1 = zeros(n, num_vars); b1 = zeros(n,1);
A2 = zeros(n, num_vars); b2 = zeros(n,1);
for t = 1:n
    A1(t, idx_P_ev_ch(t))  =  1;  A1(t, idx_u_ch(t))  = -EV_P_max;   % P_ev_ch  <= EV_P_max * u_ev_ch
    A2(t, idx_P_ev_dis(t)) =  1;  A2(t, idx_u_dis(t)) = -EV_P_max;   % P_ev_dis <= EV_P_max * u_ev_dis
end

% Availability: u_ev_ch <= a_ch ; u_ev_dis <= a_dis
A3 = zeros(n, num_vars); b3 = a_ch;
A4 = zeros(n, num_vars); b4 = a_dis;
for t = 1:n
    A3(t, idx_u_ch(t))  = 1;
    A4(t, idx_u_dis(t)) = 1;
end

% No simultaneous charge & discharge: u_ev_ch + u_ev_dis <= 1
A5 = zeros(n, num_vars); b5 = ones(n,1);
for t = 1:n
    A5(t, idx_u_ch(t))  = 1;
    A5(t, idx_u_dis(t)) = 1;
end

% Stack
A = [A1; A2; A3; A4; A5];
b = [b1; b2; b3; b4; b5];

%% ---------- Final SoC constraints ----------
idx_SOC_BESS_end = 4*n + n;   % SOC_BESS(n)
idx_SOC_EV_end   = 7*n + n;   % SOC_EV(n)

% BESS: end = start (50%)
Aeq = [Aeq; zeros(1, num_vars)];
beq = [beq; E0_BESS];
Aeq(end, idx_SOC_BESS_end) = 1;

%% ---------- Bounds ----------
lb = zeros(num_vars, 1);
ub =  inf(num_vars, 1);

% BESS power limits
ub(2*n+1:3*n) = P_bess_max;   % P_bess_ch
ub(3*n+1:4*n) = P_bess_max;   % P_bess_dis

% BESS SOC bounds
ub(4*n+1:5*n) = SOC_max;
lb(4*n+1:5*n) = SOC_min;

% EV power limits
ub(5*n+1:6*n) = EV_P_max;     % P_ev_ch
ub(6*n+1:7*n) = EV_P_max;     % P_ev_dis

% EV SOC bounds (dynamic per-hour floor)
ub(7*n+1:8*n) = EV_SOC_max;
lb(7*n+1:8*n) = EV_SOC_min_curve;     % 60% base, 80% in ready hours

% Ensure final-hour lower bound ≥80% (range-ready at end of day)
lb(idx_SOC_EV_end) = max(lb(idx_SOC_EV_end), 0.80 * EV_capacity);

% EV binaries: 0/1
ub(8*n+1:9*n)  = 1;           % u_ev_ch
ub(9*n+1:10*n) = 1;           % u_ev_dis

%% ---------- Solve MILP ----------
intcon = (8*n+1):(10*n);  % binary indices (EV on/off)
optsMILP = optimoptions('intlinprog','Display','iter');  % HiGHS default
[x, fval, exitflag] = intlinprog(f, intcon, A, b, Aeq, beq, lb, ub, optsMILP);
if exitflag ~= 1
    error('❌ Infeasible MILP. Check windows, SoC bounds, and power limits.');
end

%% ---------- Extract Results ----------
P_grid_buy = x(1:n); 
P_grid_sell= x(n+1:2*n);
P_bess_ch  = x(2*n+1:3*n); 
P_bess_dis = x(3*n+1:4*n);
SOC_BESS   = x(4*n+1:5*n);
P_ev_ch    = x(5*n+1:6*n);
P_ev_dis   = x(6*n+1:7*n);
SOC_EV     = x(7*n+1:8*n);
u_ev_ch    = x(8*n+1:9*n);
u_ev_dis   = x(9*n+1:10*n);

%% ---------- KPIs (GRID-ONLY COST) ----------
energy_cost = sum(P_grid_buy  .* Price_buy ) * dt;   % € paid to grid
energy_rev  = sum(P_grid_sell .* Price_sell) * dt;   % € earned from grid
net_cost    = energy_cost - energy_rev;

E_import   = sum(P_grid_buy)*dt;
E_export   = sum(P_grid_sell)*dt;
E_bess_ch  = sum(P_bess_ch)*dt;
E_bess_dis = sum(P_bess_dis)*dt;
E_ev_ch    = sum(P_ev_ch)*dt;
E_ev_dis   = sum(P_ev_dis)*dt;

peak_import = max(P_grid_buy);
peak_export = max(P_grid_sell);

cycles_BESS = E_bess_dis / BESS_capacity;   % discharge-throughput based
cycles_EV   = E_ev_dis   / EV_capacity;

load_energy = sum(Load)*dt;
self_sufficiency = max(0, 1 - E_import / max(1e-9, load_energy));

gen_total = PV + Wind + Biogas;
ren_share_of_load = sum(min(gen_total, Load))*dt / max(1e-9, load_energy);

fprintf('\n--- KPIs (GRID-ONLY COST) ---\n');
fprintf('Energy cost (buy):       €%.2f\n', energy_cost);
fprintf('Energy revenue (sell):   €%.2f\n', energy_rev);
fprintf('Net cost:                €%.2f\n', net_cost);
fprintf('Energy import/export (kWh): %.1f / %.1f\n', E_import, E_export);
fprintf('EV charge/discharge (kWh):  %.1f / %.1f\n', E_ev_ch, E_ev_dis);
fprintf('BESS charge/discharge (kWh): %.1f / %.1f\n', E_bess_ch, E_bess_dis);
fprintf('Peak import/export (kW): %.1f / %.1f\n', peak_import, peak_export);
fprintf('BESS cycles (≈): %.2f   | EV cycles (≈): %.2f\n', cycles_BESS, cycles_EV);
fprintf('Self-sufficiency: %.1f%%  | Rough renewable-share of load: %.1f%%\n', ...
        100*self_sufficiency, 100*ren_share_of_load);
fprintf('Final SoC targets met?  BESS: %.1f%%  EV: %.1f%%\n', ...
    100*SOC_BESS(end)/BESS_capacity, 100*SOC_EV(end)/EV_capacity);

%% ---------- Plots ----------
SOC_BESS_pct    = (SOC_BESS / BESS_capacity) * 100;
SOC_EV_pct      = (SOC_EV   / EV_capacity)   * 100;
SOC_BESS_min_pct= (SOC_min  / BESS_capacity) * 100;
SOC_BESS_max_pct= (SOC_max  / BESS_capacity) * 100;
SOC_EV_max_pct  = (EV_SOC_max / EV_capacity) * 100;
SOC_EV_min_pct_curve = (EV_SOC_min_curve / EV_capacity) * 100;

% 1) BESS Charging / Discharging and SOC
figure;
subplot(3,1,1);
bar(P_bess_ch, 'FaceColor', [1 0.5 0]); hold on;
bar(-P_bess_dis, 'FaceColor', [0 0.7 0.7]);
ylabel('Power (kW)'); title('BESS Charging / Discharging');
legend('Charging', 'Discharging'); grid on;

subplot(3,1,2);
plot(SOC_BESS_pct, '-o', 'LineWidth', 2); hold on;
yline(SOC_BESS_min_pct, '--r', 'Min SOC'); 
yline(SOC_BESS_max_pct, '--r', 'Max SOC');
ylabel('SOC (%)'); xlabel('Hour'); title('BESS SOC (%)'); grid on;
legend('BESS SOC (%)', 'Min SOC', 'Max SOC');

% 2) EV Charging / Discharging and SOC (+ binaries)
subplot(3,1,3);
yyaxis left;
bar(P_ev_ch, 'FaceColor', [0.2 0.7 0.2]); hold on;
bar(-P_ev_dis, 'FaceColor', [0.6 0 0.6]);
ylabel('Power (kW)');
yyaxis right;
plot(SOC_EV_pct, '-d', 'LineWidth', 2); hold on;
stairs(SOC_EV_min_pct_curve, '--', 'LineWidth', 1.5); % dynamic floor
stairs(u_ev_ch*100, ':',  'LineWidth', 1.2);
stairs(u_ev_dis*100, '-.', 'LineWidth', 1.2);
ylabel('EV SOC (%) / ON-OFF (%)');
xlabel('Hour'); title('EV Charging / Discharging & SOC (with ON/OFF & Min Curve)');
legend('EV Charge', 'EV Discharge', 'EV SOC', 'EV Min SOC (dyn)', 'u\_ev\_ch', 'u\_ev\_dis'); grid on;

% 3) Grid Interaction
figure;
bar(P_grid_buy, 'b'); hold on;
bar(-P_grid_sell, 'r');
xlabel('Hour'); ylabel('Grid Power (kW)');
legend('Grid Import', 'Grid Export'); title('Grid Interaction'); grid on;

% 4) Generation by Source (PV, Wind, Biogas) + Prices 
figure;
yyaxis left;
plot(1:n, PV,     '-o', 'LineWidth', 1.5, 'Color', [0.85 0.33 0.1], 'DisplayName', 'PV'); hold on;
plot(1:n, Wind,   '-s', 'LineWidth', 1.5, 'Color', [0 0.45 0.74],   'DisplayName', 'Wind');
plot(1:n, Biogas, '-d', 'LineWidth', 1.5, 'Color', [0.47 0.67 0.19],'DisplayName', 'Biogas');
ylabel('Power (kW)');
ylim([0, max([PV; Wind; Biogas; Load]) + 10]);

yyaxis right;
plot(1:n, Price_buy,  '-o', 'LineWidth', 2, 'Color', [0.75 0 0.75], 'DisplayName', 'Buy Price'); hold on;
plot(1:n, Price_sell, '-x', 'LineWidth', 1.5, 'Color', [0.49 0 0.49], 'DisplayName', 'Sell Price');
ylabel('Price (€/kWh)');
ylim([min([Price_buy;Price_sell])*0.95, max([Price_buy;Price_sell])*1.05]);

xlabel('Hour');
title('Generation by Source & Electricity Prices');
legend('Location', 'northwest');
grid on;

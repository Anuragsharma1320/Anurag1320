close all; clear; clc;

%% ---------- Load Data ----------
data   = readtable('MG-data-0.xlsx');
PV     = data.PV(:);
Wind   = data.Wind(:);
Biogas = data.Biogas(:);
Load   = data.Demand(:);
Price  = data.Price(:);           % €/kWh

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

%% ---------- Init ----------
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

%% ---------- Main loop (priority-free, proportional, price-aware) ----------
for t = 1:n
    gen = PV(t) + Wind(t) + Biogas(t);
    total_gen(t)     = gen;
    power_balance(t) = gen - Load(t);

    p_now   = Price_buy(t);
    p_sell  = Price_sell(t);
    if t < n
        p_future_min_buy  = min(Price_buy(t+1:n));
        p_future_max_sell = max(Price_sell(t+1:n));
    else
        p_future_min_buy  = p_now;
        p_future_max_sell = p_sell;
    end

    % ---- Per-hour storage limits (respect dynamic EV min curve) ----
    % BESS
    headroom_bess  = max(0, (SOCmax_BESS - E_BESS)/eta_b_ch);
    deliver_bess   = max(0, (E_BESS - SOCmin_BESS)*eta_b_dis);
    ch_cap_bess    = min(P_bess_max, headroom_bess);
    dis_cap_bess   = min(P_bess_max, deliver_bess);

    % EV (time-varying lower bound)
    SOCmin_EV_t    = EV_SOC_min_curve(t);
    can_charge_ev  = a_ch(t)  && (E_EV < SOCmax_EV);
    can_dis_ev     = a_dis(t) && (E_EV > SOCmin_EV_t);
    headroom_ev    = can_charge_ev * max(0, (SOCmax_EV - E_EV)/eta_ev_ch);
    deliver_ev     = can_dis_ev   * max(0, (E_EV - SOCmin_EV_t)*eta_ev_dis);
    ch_cap_ev      = min(EV_P_max, headroom_ev);
    dis_cap_ev     = min(EV_P_max, deliver_ev);

    ch_cap_total   = ch_cap_bess + ch_cap_ev;
    dis_cap_total  = dis_cap_bess + dis_cap_ev;

    % ---- Desired net storage action S_des (+ch, -dis) ----
    resid = power_balance(t);
    want_extra_charge    = (p_now < p_future_min_buy  - eps_price);
    want_extra_discharge = (p_now > p_future_max_sell + eps_price);

    if resid > 0
        S_des = min(resid, ch_cap_total);
        if want_extra_charge
            S_des = min(ch_cap_total, ch_cap_total); % top-up if cheap
        end
    elseif resid < 0
        S_des = -min(-resid, dis_cap_total);
        if want_extra_discharge
            S_des = -min(dis_cap_total, dis_cap_total); % extra export if rich price
        end
    else
        if     want_extra_charge,    S_des =  ch_cap_total;
        elseif want_extra_discharge, S_des = -dis_cap_total;
        else,  S_des = 0;
        end
    end

    % Safety clamp
    S_des = max(-dis_cap_total, min(S_des, ch_cap_total));

    % ---- Allocate proportional to available capability (no fixed priority) ----
    if S_des >= 0
        w_b = ch_cap_bess; w_e = ch_cap_ev; denom = max(1e-12, w_b + w_e);
        P_b = min(ch_cap_bess, S_des*(w_b/denom));
        P_e = min(ch_cap_ev,   S_des*(w_e/denom));
        E_BESS = E_BESS + eta_b_ch*P_b;
        E_EV   = E_EV   + eta_ev_ch*P_e;
    else
        S_dis = -S_des;
        w_b = dis_cap_bess; w_e = dis_cap_ev; denom = max(1e-12, w_b + w_e);
        d_b = min(dis_cap_bess, S_dis*(w_b/denom));
        d_e = min(dis_cap_ev,   S_dis*(w_e/denom));
        P_b = -d_b;  P_e = -d_e;
        E_BESS = E_BESS - d_b/eta_b_dis;
        E_EV   = E_EV   - d_e/eta_ev_dis;
    end

    % Store
    P_BESS(t)        = P_b;
    P_EV(t)          = P_e;
    SOCpct_BESS(t+1) = 100*E_BESS/BESS_capacity;
    SOCpct_EV(t+1)   = 100*E_EV/EV_capacity;

    % Grid interaction
    Pgrid(t) = -(power_balance(t) - P_BESS(t) - P_EV(t));
end

%% ---------- Final SoC correction ----------
% BESS: return to 50%
E_BESS_target = (SOCpct_BESS_0/100)*BESS_capacity;
% EV: exact 80% at end of day
E_EV_target   = EV_final_target;

t = n;

% Compute required net bus-side actions
dE_bess = E_BESS_target - E_BESS; % + need to charge, - need to discharge
dE_ev   = E_EV_target   - E_EV;   % + need to charge, - need to discharge

% Per-hour caps at final hour t (respect windows & dynamic EV min)
SOCmin_EV_t = EV_SOC_min_curve(t);
ch_cap_bess = min(P_bess_max, max(0,(SOCmax_BESS - E_BESS)/eta_b_ch));
dis_cap_bess= min(P_bess_max, max(0,(E_BESS - SOCmin_BESS)*eta_b_dis));
ch_cap_ev   = min(EV_P_max,   (a_ch(t)*max(0,(SOCmax_EV - E_EV)/eta_ev_ch)));
dis_cap_ev  = min(EV_P_max,   (a_dis(t)*max(0,(E_EV - SOCmin_EV_t)*eta_ev_dis)));

% Charge needs
need_in_bess = max(0, dE_bess/eta_b_ch);
need_in_ev   = max(0, dE_ev/eta_ev_ch);

add_b = min(ch_cap_bess, need_in_bess);
add_e = min(ch_cap_ev,   need_in_ev);

P_BESS(t) = P_BESS(t) + add_b;   E_BESS = E_BESS + eta_b_ch*add_b;
P_EV(t)   = P_EV(t)   + add_e;   E_EV   = E_EV   + eta_ev_ch*add_e;
Pgrid(t)  = Pgrid(t)  + (add_b + add_e);

% If there is a negative dE (excess energy), discharge within caps
need_out_bess = max(0, -dE_bess*eta_b_dis);
need_out_ev   = max(0, -dE_ev*eta_ev_dis);

d_b = min(dis_cap_bess, need_out_bess);
d_e = min(dis_cap_ev,   need_out_ev);

P_BESS(t) = P_BESS(t) - d_b;   E_BESS = E_BESS - d_b/eta_b_dis;
P_EV(t)   = P_EV(t)   - d_e;   E_EV   = E_EV   - d_e/eta_ev_dis;
Pgrid(t)  = Pgrid(t)  - (d_b + d_e);

% Final SoC (reporting)
SOCpct_BESS(end) = 100*E_BESS/BESS_capacity;
SOCpct_EV(end)   = 100*E_EV/EV_capacity;

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

%% ---------- Plots ----------
SOC_BESS_min_pct = 100*SOCmin_BESS/BESS_capacity;
SOC_BESS_max_pct = 100*SOCmax_BESS/BESS_capacity;
SOC_EV_max_pct   = 100*SOCmax_EV/EV_capacity;
SOC_EV_min_pct_curve = 100*EV_SOC_min_curve/EV_capacity;

% 1) BESS Charging / Discharging and SOC
figure;
subplot(3,1,1);
bar(max(P_BESS,0),'FaceColor',[1 0.5 0]); hold on;
bar(-max(-P_BESS,0),'FaceColor',[0 0.7 0.7]);
ylabel('Power (kW)'); title('BESS Charging / Discharging');
legend('Charging','Discharging'); grid on;

subplot(3,1,2);
plot(SOCpct_BESS,'-o','LineWidth',2); hold on;
yline(SOC_BESS_min_pct,'--r','Min SOC');
yline(SOC_BESS_max_pct,'--r','Max SOC');
ylabel('SOC (%)'); xlabel('Hour'); title('BESS SOC (%)'); grid on;
legend('BESS SOC','Min','Max');

% 2) EV Charging / Discharging and SOC (+ windows & dynamic min)
subplot(3,1,3);
yyaxis left;
bar(max(P_EV,0),'FaceColor',[0.2 0.7 0.2]); hold on;
bar(-max(-P_EV,0),'FaceColor',[0.6 0 0.6]);
ylabel('Power (kW)');
yyaxis right;
plot(SOCpct_EV,'-d','LineWidth',2); hold on;
stairs(SOC_EV_min_pct_curve,'--','LineWidth',1.5);   % dynamic floor
stairs(100*a_ch,':','LineWidth',1.2);                % charge window
stairs(100*a_dis,'-.','LineWidth',1.2);              % discharge window
ylabel('EV SOC (%) / ON-OFF (%)');
xlabel('Hour'); title('EV Charging / Discharging & SOC (with windows & min curve)');
legend('EV Charge','EV Discharge','EV SOC','EV Min SOC (dyn)','Charge window','Discharge window'); grid on;

% 3) Grid Interaction
figure;
bar(max(Pgrid,0),'b'); hold on;
bar(-max(-Pgrid,0),'r');
xlabel('Hour'); ylabel('Grid Power (kW)');
legend('Grid Import','Grid Export'); title('Grid Interaction'); grid on;

% 4) Generation by Source + Prices
figure;
yyaxis left;
plot(1:n, PV,    '-o','LineWidth',1.5,'Color',[0.85 0.33 0.1]); hold on;
plot(1:n, Wind,  '-s','LineWidth',1.5,'Color',[0 0.45 0.74]);
plot(1:n, Biogas,'-d','LineWidth',1.5,'Color',[0.47 0.67 0.19]);
ylabel('Power (kW)');
ylim([0, max([PV;Wind;Biogas;Load])+10]);

yyaxis right;
plot(1:n, Price_buy, '-o','LineWidth',2,  'Color',[0.75 0 0.75]); hold on;
plot(1:n, Price_sell,'-x','LineWidth',1.5,'Color',[0.49 0 0.49]);
ylabel('Price (€/kWh)');
ylim([min([Price_buy;Price_sell])*0.95, max([Price_buy;Price_sell])*1.05]);
xlabel('Hour'); title('Generation by Source & Electricity Prices');
legend('Location','northwest'); grid on;

% 5) Generation vs Demand vs Balance
figure; hold on;
plot(1:n, total_gen, '-o','DisplayName','Total Generation','LineWidth',1.5);
plot(1:n, Load,      '-o','DisplayName','Demand','LineWidth',1.5);
area(1:n, total_gen-Load, 'FaceColor',[0 1 1], 'FaceAlpha',0.25, ...
    'EdgeColor',[0 0.4 1], 'DisplayName','Gen-Load');
xlabel('Hour'); ylabel('P (kW)');
title('Total Generation, Demand, and Power Balance');
legend; grid on; hold off;








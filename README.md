# Analysis-of-renewable-based-energy-management-in-microgrids-with-integration-of-bess-with/without-EV (V2G)
**MATLAB-based controller implementing dynamic SOC constraints for EV and battery storage system, real-time price-driven charging/discharging, and KPI analysis for grid cost and self-sufficiency optimization in order to achieve cost optimal operation with the integration of EV with BESS.**

**Motivation**:
Rule-based control offers a practical alternative to computationally expensive optimization methods (like MILP).
It is simple, fast, and transparent, making it suitable for on-site controllers, EV charging hubs, and industrial microgrids where reliability and interpretability are prioritized over full optimality.

**System Overview**

1) **Components**: PV array, Wind turbine, Biogass, Battery Energy Storage System (BESS), Electric Vehicle (EV), Grid.

2) **Inputs**: PV, Wind, Load, Biogass, and Electricity Price data.

3) **Outputs**: SOC profiles, Power flows, Grid import/export, Cost, and Renewable share KPIs.

**Conclusion**:
The outcome of this research demonstrates that rule-based control strategies can effectively manage renewable driven microgrids with low computational effort, high reliability, and robust integration of EVs (V2G/G2V) and storage systems. The system achieve 14% cost reduction with the integration of electric vehicle with self-sufficiency 84%.
The approach bridges the gap between academic optimization models and industrial real-time control, offering a scalable, cost-efficient solution that supports Germany’s transition toward decentralized, flexible, and electrified energy systems. But solutions are suboptimal and requires more decision logic to achieve near optimal solution.

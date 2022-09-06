# *********************************************************************************
# REopt, Copyright (c) 2019-2020, Alliance for Sustainable Energy, LLC.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this list
# of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or other
# materials provided with the distribution.
#
# Neither the name of the copyright holder nor the names of its contributors may be
# used to endorse or promote products derived from this software without specific
# prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
# OF THE POSSIBILITY OF SUCH DAMAGE.
# *********************************************************************************
"""
	add_re_elec_constraints(m,p)

Function to add minimum and/or maximum renewable electricity (as percentage of load) constraints, if specified by user.

!!! note
    When a single outage is modeled (using outage_start_time_step), renewable electricity calculations account for operations during this outage (e.g., the critical load is used during time_steps_without_grid)
	On the contrary, when multiple outages are modeled (using outage_start_time_steps), renewable electricity calculations reflect normal operations, and do not account for expected operations during modeled outages (time_steps_without_grid is empty)
"""
#Renewable electricity constraints
function add_re_elec_constraints(m,p)
	if !isnothing(p.s.site.renewable_electricity_min_fraction)
		@constraint(m, MinREElecCon, m[:AnnualREEleckWh] >= p.s.site.renewable_electricity_min_fraction*m[:AnnualEleckWh])
	end
	if !isnothing(p.s.site.renewable_electricity_max_fraction)
		@constraint(m, MaxREElecCon, m[:AnnualREEleckWh] <= p.s.site.renewable_electricity_max_fraction*m[:AnnualEleckWh])
	end
end


"""
	add_re_elec_calcs(m,p)

Function to calculate annual electricity demand and annual electricity demand derived from renewable energy.

!!! note
    When a single outage is modeled (using outage_start_time_step), renewable electricity calculations account for operations during this outage (e.g., the critical load is used during time_steps_without_grid)
	On the contrary, when multiple outages are modeled (using outage_start_time_steps), renewable electricity calculations reflect normal operations, and do not account for expected operations during modeled outages (time_steps_without_grid is empty)
"""
# Renewable electricity calculation
function add_re_elec_calcs(m,p)

	# TODO: When steam turbine implemented, uncomment code below, replacing p.TechCanSupplySteamTurbine, p.STElecOutToThermInRatio with new names
	# # Steam turbine RE elec calculations 
	# if isempty(p.steam)
	# 	SteamTurbineAnnualREEleckWh = 0 
    # else  
	# 	# Note: SteamTurbine's input p.tech_renewable_energy_pct = 0 because it is actually a decision variable dependent on fraction of steam generated by RE fuel
	# 	SteamTurbinePercentREEstimate = @expression(m,
	# 		sum(p.tech_renewable_energy_pct[tst] for tst in p.TechCanSupplySteamTurbine) / length(p.TechCanSupplySteamTurbine)
	# 	)
	# 	# Note: Steam turbine battery losses, curtailment, and exported RE terms are only accurate if all techs that can supply ST 
	# 	#		have equal RE%, otherwise it is an approximation because the general equation is non linear. 
	# 	SteamTurbineAnnualREEleckWh = @expression(m,p.hours_per_time_step * (
	# 		p.STElecOutToThermInRatio * sum(m[:dvThermalToSteamTurbine][tst,ts]*p.tech_renewable_energy_pct[tst] for ts in p.time_steps, tst in p.TechCanSupplySteamTurbine) # plus steam turbine RE generation 
	# 		- sum(m[:dvProductionToStorage][b,t,ts] * SteamTurbinePercentREEstimate * (1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) for t in p.steam, b in p.s.storage.types.elec, ts in p.time_steps) # minus battery storage losses from RE from steam turbine
	# 		- sum(m[:dvCurtail][t,ts] * SteamTurbinePercentREEstimate for t in p.steam, ts in p.time_steps) # minus curtailment.
	# 		- (1-p.s.site.include_exported_renewable_electricity_in_total)*sum(m[:dvProductionToGrid][t,u,ts]*SteamTurbinePercentREEstimate for t in p.steam,  u in p.export_bins_by_tech[t], ts in p.time_steps) # minus exported RE from steam turbine, if RE accounting method = 0.
	# 	))
	# end

	m[:AnnualREEleckWh] = @expression(m,p.hours_per_time_step * (
			sum(p.production_factor[t,ts] * p.levelization_factor[t] * m[:dvRatedProduction][t,ts] * 
				p.tech_renewable_energy_pct[t] for t in p.techs.elec, ts in p.time_steps
			) - #total RE elec generation, excl steam turbine
			sum(m[:dvProductionToStorage][b,t,ts]*p.tech_renewable_energy_pct[t]*(
				1-p.s.storage.attr[b].charge_efficiency*p.s.storage.attr[b].discharge_efficiency) 
				for t in p.techs.elec, b in p.s.storage.types.elec, ts in p.time_steps
			) - #minus battery efficiency losses
			sum(m[:dvCurtail][t,ts]*p.tech_renewable_energy_pct[t] for t in p.techs.elec, ts in p.time_steps) - # minus curtailment.
			(1 - p.s.site.include_exported_renewable_electricity_in_total) *
			sum(m[:dvProductionToGrid][t,u,ts]*p.tech_renewable_energy_pct[t] 
				for t in p.techs.elec,  u in p.export_bins_by_tech[t], ts in p.time_steps
			) # minus exported RE, if RE accounting method = 0.
		)
		# + SteamTurbineAnnualREEleckWh  # SteamTurbine RE Elec, already adjusted for p.hours_per_time_step
	)		
    # Note: if battery ends up being allowed to discharge to grid, need to make sure only RE that is being consumed onsite is counted so battery doesn't become a back door for RE to grid.
	# Note: calculations currently do not ascribe any renewable energy attribute to grid-purchased electricity

	m[:AnnualEleckWh] = @expression(m,p.hours_per_time_step * (
		 	# input electric load
			sum(p.s.electric_load.loads_kw[ts] for ts in p.time_steps_with_grid) 
			+ sum(p.s.electric_load.critical_loads_kw[ts] for ts in p.time_steps_without_grid)
			# tech electric loads
			# + sum(m[:dvThermalProduction][t,ts] for t in p.ElectricChillers, ts in p.time_steps )/ p.ElectricChillerCOP # electric chiller elec load
			# + sum(m[:dvThermalProduction][t,ts] for t in p.AbsorptionChillers, ts in p.time_steps )/ p.AbsorptionChillerElecCOP # absorportion chiller elec load
			# + sum(p.GHPElectricConsumed[g,ts] * m[:binGHP][g] for g in p.GHPOptions, ts in p.time_steps) # GHP elec load
		)
	)
	nothing
end
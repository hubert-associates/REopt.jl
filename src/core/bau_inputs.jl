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

Create a REoptInputs for the Business As Usual scenario.
"""
function BAUInputs(p::REoptInputs)
    bau_scenario = BAUScenario(p.s)
    techs = Techs(p, bau_scenario)

    boiler_efficiency = Dict{String, Float64}()

    # REoptInputs indexed on techs.all:
    max_sizes = Dict(t => 0.0 for t in techs.all)
    min_sizes = Dict(t => 0.0 for t in techs.all)
    existing_sizes = Dict(t => 0.0 for t in techs.all)
    cap_cost_slope = Dict{String, Any}()
    om_cost_per_kw = Dict(t => 0.0 for t in techs.all)
    cop = Dict(t => 0.0 for t in techs.cooling)
    production_factor = DenseAxisArray{Float64}(undef, techs.all, p.time_steps)
    tech_renewable_energy_pct = Dict(t => p.tech_renewable_energy_pct[t] for t in techs.all)
    # !!! note: tech_emissions_factors in lb / kWh (gets multiplied by kWh of fuel burned, not kWh electricity consumption, ergo the use of the HHV instead of fuel slope)
    tech_emissions_factors_CO2 = Dict(t => p.tech_emissions_factors_CO2[t] for t in techs.all)
    tech_emissions_factors_NOx = Dict(t => p.tech_emissions_factors_NOx[t] for t in techs.all)
    tech_emissions_factors_SO2 = Dict(t => p.tech_emissions_factors_SO2[t] for t in techs.all)
    tech_emissions_factors_PM25 = Dict(t => p.tech_emissions_factors_PM25[t] for t in techs.all)

    # export related inputs
    techs_by_exportbin = Dict{Symbol, AbstractArray}(k => [] for k in p.s.electric_tariff.export_bins)
    export_bins_by_tech = Dict{String, Array{Symbol, 1}}()

    # REoptInputs indexed on techs.segmented
    n_segs_by_tech = Dict{String, Int}()
    seg_min_size = Dict{String, Dict{Int, Float64}}()
    seg_max_size = Dict{String, Dict{Int, Float64}}()
    seg_yint = Dict{String, Dict{Int, Float64}}()

    # PV specific arrays
    pv_to_location = Dict(t => Dict{Symbol, Int}() for t in techs.pv)

    levelization_factor = Dict(t => 1.0 for t in techs.all)

    for pvname in techs.pv  # copy the optimal scenario inputs for existing PV systems
        production_factor[pvname, :] = p.production_factor[pvname, :]
        pv_to_location[pvname] = p.pv_to_location[pvname]
        existing_sizes[pvname] = p.existing_sizes[pvname]
        min_sizes[pvname] = p.existing_sizes[pvname]
        max_sizes[pvname] = p.existing_sizes[pvname]
        om_cost_per_kw[pvname] = p.om_cost_per_kw[pvname]
        levelization_factor[pvname] = p.levelization_factor[pvname]
        cap_cost_slope[pvname] = 0.0
        if pvname in p.techs.pbi
            push!(pbi_techs, pvname)
        end
        pv = get_pv_by_name(pvname, p.s.pvs)
        fillin_techs_by_exportbin(techs_by_exportbin, pv, pv.name)
        if !pv.can_curtail
            push!(techs.no_curtail, pv.name)
        end
    end

    if "Generator" in techs.all
        max_sizes["Generator"] = p.s.generator.existing_kw
        min_sizes["Generator"] = p.s.generator.existing_kw
        existing_sizes["Generator"] = p.s.generator.existing_kw
        cap_cost_slope["Generator"] = 0.0
        om_cost_per_kw["Generator"] = p.s.generator.om_cost_per_kw
        production_factor["Generator", :] = p.production_factor["Generator", :]
        fillin_techs_by_exportbin(techs_by_exportbin, p.s.generator, "Generator")
        if "Generator" in p.techs.pbi
            push!(pbi_techs, "Generator")
        end
        if !p.s.generator.can_curtail
            push!(techs.no_curtail, "Generator")
        end
    end

    if "ExistingBoiler" in techs.all
        setup_existing_boiler_inputs(bau_scenario, max_sizes, min_sizes, existing_sizes, cap_cost_slope, boiler_efficiency)
    end

    if "ExistingChiller" in techs.all
        setup_existing_chiller_inputs(bau_scenario, max_sizes, min_sizes, existing_sizes, cap_cost_slope, cop)
    else
        cop["ExistingChiller"] = 1.0
    end

    # filling export_bins_by_tech MUST be done after techs_by_exportbin has been filled in
    for t in techs.elec
        export_bins_by_tech[t] = [bin for (bin, ts) in techs_by_exportbin if t in ts]
    end

    t0, tf = p.s.electric_utility.outage_start_time_step, p.s.electric_utility.outage_end_time_step
    if tf > t0 && t0 > 0
        original_crit_lds = copy(p.s.electric_load.critical_loads_kw)
        generator_fuel_use_gal = update_bau_outage_outputs(bau_scenario, original_crit_lds, t0, tf, production_factor)

        if bau_scenario.outage_outputs.bau_critical_load_met_time_steps > 0  
        # include critical load in bau load for the time that it can be met
            bau_scenario.electric_load.critical_loads_kw[
                t0 : t0 + bau_scenario.outage_outputs.bau_critical_load_met_time_steps
                ] = original_crit_lds[t0 : t0 + bau_scenario.outage_outputs.bau_critical_load_met_time_steps]
        end

        setup_bau_emissions_inputs(p.s, bau_scenario, production_factor, levelization_factor, generator_fuel_use_gal)
    end

    REoptInputs(
        bau_scenario,
        techs,
        min_sizes,
        max_sizes,
        existing_sizes,
        cap_cost_slope,
        om_cost_per_kw,
        cop,
        p.time_steps,
        p.time_steps_with_grid,
        p.time_steps_without_grid,
        p.hours_per_timestep,
        p.months,
        production_factor,
        levelization_factor,
        p.value_of_lost_load_per_kwh,
        p.pwf_e,
        p.pwf_om,
        p.pwf_fuel,
        p.pwf_emissions_cost,
        p.pwf_grid_emissions_lbs,
        p.third_party_factor,
        p.pvlocations,
        p.maxsize_pv_locations,
        pv_to_location,
        p.ratchets,
        techs_by_exportbin,
        export_bins_by_tech,
        n_segs_by_tech,
        seg_min_size,
        seg_max_size,
        seg_yint,
        p.pbi_pwf, 
        p.pbi_max_benefit, 
        p.pbi_max_kw, 
        p.pbi_benefit_per_kwh,
        boiler_efficiency,
        tech_renewable_energy_pct, 
        tech_emissions_factors_CO2, 
        tech_emissions_factors_NOx, 
        tech_emissions_factors_SO2, 
        tech_emissions_factors_PM25
    )
end


"""
    update_bau_emissions_inputs(s::AbstractScenario, bau_emissions_lb_CO2_per_year, bau_emissions_lb_NOx_per_year, 
        bau_emissions_lb_SO2_per_year, bau_emissions_lb_PM25_per_year, bau_grid_emissions_lb_CO2_per_year, 
        bau_grid_emissions_lb_NOx_per_year, bau_grid_emissions_lb_SO2_per_year, bau_grid_emissions_lb_PM25_per_year)

Update the `bau_(grid_)emissions_` values in s.site
"""
function update_bau_emissions_inputs(s::AbstractScenario, bau_emissions_lb_CO2_per_year, bau_emissions_lb_NOx_per_year, 
            bau_emissions_lb_SO2_per_year, bau_emissions_lb_PM25_per_year, bau_grid_emissions_lb_CO2_per_year, 
            bau_grid_emissions_lb_NOx_per_year, bau_grid_emissions_lb_SO2_per_year, bau_grid_emissions_lb_PM25_per_year)
    
    s.site.bau_emissions_lb_CO2_per_year = bau_emissions_lb_CO2_per_year
    s.site.bau_emissions_lb_NOx_per_year = bau_emissions_lb_NOx_per_year
    s.site.bau_emissions_lb_SO2_per_year = bau_emissions_lb_SO2_per_year
    s.site.bau_emissions_lb_PM25_per_year = bau_emissions_lb_PM25_per_year

    s.site.bau_grid_emissions_lb_CO2_per_year = bau_grid_emissions_lb_CO2_per_year
    s.site.bau_grid_emissions_lb_NOx_per_year = bau_grid_emissions_lb_NOx_per_year
    s.site.bau_grid_emissions_lb_SO2_per_year = bau_grid_emissions_lb_SO2_per_year
    s.site.bau_grid_emissions_lb_PM25_per_year = bau_grid_emissions_lb_PM25_per_year
end

"""
    setup_bau_emissions_inputs(s::Scenario, s_bau::BAUScenario, production_factor::DenseAxisArray, levelization_factor::Dict{String, Float64}, generator_fuel_use_gal::Float64)

Pre-processing of the BAU emissions to use in determining emissions reductions in the optimal case
Include BAU grid emissions, existing backup generator emissions, boiler emissions
Update the `bau_(grid_)emissions_` values in s.site and s_bau.site

Note if existing generation does not sustain a simulated outage, the BAU load and therefore emissions
are 0 during unsurvived outage hours
"""
function setup_bau_emissions_inputs(s::Scenario, s_bau::BAUScenario, production_factor::DenseAxisArray, levelization_factor::Dict{String, Float64}, generator_fuel_use_gal::Float64)
    
    bau_emissions_lb_CO2_per_year = 0
    bau_emissions_lb_NOx_per_year = 0
    bau_emissions_lb_SO2_per_year = 0
    bau_emissions_lb_PM25_per_year = 0

    ## Grid emissions

    # This function is called after ajust_load_profile() (makes load_kw native if not already) 
    # so need to calculate net version of loads_kw by removing existing PV to get load served by the grid.
    # TODO: Should load_profile have loads_kw and loads_kw_net fields, instead of updating loads_kw? Would be easier 
    # to keep track of what version you're using, don't have to make sure whether it's before or after the adjustment.
    # Must account for levelization factor to align with how PV is modeled in REopt:
    # Because we only model one year, we multiply the "year 1" PV production by a levelization_factor
    # that accounts for the PV capacity degradation over the analysis_years. In other words, by
    # multiplying the pv.prod_factor by the levelization_factor we are modeling the average pv production.
    bau_grid_to_load = s_bau.electric_load.loads_kw
    bau_grid_to_load_critical = s_bau.electric_load.critical_loads_kw
    for pv in s.pvs if pv.existing_kw > 0
        bau_grid_to_load .-= levelization_factor[pv.name] * pv.existing_kw * production_factor[pv.name, :].data
    end end
    for pv in s.pvs if pv.existing_kw > 0
        bau_grid_to_load_critical .-= levelization_factor[pv.name] * pv.existing_kw * production_factor[pv.name, :].data
    end end

    #No grid emissions, or pv exporting to grid, during an outage
    if s.electric_load.outage_start_time_step != 0 && s.electric_load.outage_end_time_step != 0
        for i in range(s.electric_load.outage_start_time_step, stop=s.electric_load.outage_end_time_step)
            bau_grid_to_load[i] = 0
        end
    end

    #If no net emissions accounting, no credit for RE grid exports:
    if !s.site.include_exported_elec_emissions_in_total
        bau_grid_to_load = [max(i,0) for i in bau_grid_to_load]
    end

    steplength = 8760.0 / s.settings.time_steps_per_hour
    bau_grid_emissions_lb_CO2_per_year = steplength*sum(s.electric_tariff.emissions_factor_series_lb_CO2_per_kwh .* bau_grid_to_load)
    bau_emissions_lb_CO2_per_year += bau_grid_emissions_lb_CO2_per_year

    bau_grid_emissions_lb_NOx_per_year = steplength*sum(s.electric_tariff.emissions_factor_series_lb_NOx_per_kwh .* bau_grid_to_load)
    bau_emissions_lb_NOx_per_year += bau_grid_emissions_lb_NOx_per_year

    bau_grid_emissions_lb_SO2_per_year = steplength*sum(s.electric_tariff.emissions_factor_series_lb_SO2_per_kwh .* bau_grid_to_load)
    bau_emissions_lb_SO2_per_year += bau_grid_emissions_lb_SO2_per_year

    bau_grid_emissions_lb_PM25_per_year = steplength*sum(s.electric_tariff.emissions_factor_series_lb_PM25_per_kwh .* bau_grid_to_load)
    bau_emissions_lb_PM25_per_year += bau_grid_emissions_lb_PM25_per_year

    ## Generator emissions (during outages)
    if "Generator" in s.techs.all
        bau_emissions_lb_CO2_per_year += generator_fuel_use_gal * s.generator.emissions_factor_lb_CO2_per_gal
        bau_emissions_lb_NOx_per_year += generator_fuel_use_gal * s.generator.emissions_factor_lb_NOx_per_gal
        bau_emissions_lb_SO2_per_year += generator_fuel_use_gal * s.generator.emissions_factor_lb_SO2_per_gal
        bau_emissions_lb_PM25_per_year += generator_fuel_use_gal * s.generator.emissions_factor_lb_PM25_per_gal
    end

    ## Boiler emissions
    if "ExistingBoiler" in s.techs.all
        for heat_type in ["space_heating", "dhw"] #TODO: are these heating types the same? can we get them from s?
            bau_emissions_lb_CO2_per_year += eval("s.$(heat_type)_load.annual_mmbtu") * s.existing_boiler.emissions_factor_lb_CO2_per_mmbtu
            bau_emissions_lb_NOx_per_year += eval("s.$(heat_type)_load.annual_mmbtu") * s.existing_boiler.emissions_factor_lb_NOx_per_mmbtu
            bau_emissions_lb_SO2_per_year += eval("s.$(heat_type)_load.annual_mmbtu") * s.existing_boiler.emissions_factor_lb_SO2_per_mmbtu
            bau_emissions_lb_PM25_per_year += eval("s.$(heat_type)_load.annual_mmbtu") * s.existing_boiler.emissions_factor_lb_PM25_per_mmbtu
        end
    end

    update_bau_emissions_inputs(s, bau_emissions_lb_CO2_per_year, bau_emissions_lb_NOx_per_year, 
                                bau_emissions_lb_SO2_per_year, bau_emissions_lb_PM25_per_year, 
                                bau_grid_emissions_lb_CO2_per_year, bau_grid_emissions_lb_NOx_per_year, 
                                bau_grid_emissions_lb_SO2_per_year, bau_grid_emissions_lb_PM25_per_year)
    update_bau_emissions_inputs(s_bau, bau_emissions_lb_CO2_per_year, bau_emissions_lb_NOx_per_year, 
                                bau_emissions_lb_SO2_per_year, bau_emissions_lb_PM25_per_year, 
                                bau_grid_emissions_lb_CO2_per_year, bau_grid_emissions_lb_NOx_per_year, 
                                bau_grid_emissions_lb_SO2_per_year, bau_grid_emissions_lb_PM25_per_year)
end


"""
    update_bau_outage_outputs(s::BAUScenario, crit_load, t0, tf, production_factors)

Update the `bau_critical_load_met` and `bau_critical_load_met_time_steps`  values.

return: Float for the gallons of fuel used trying to meet critical load

"""
function update_bau_outage_outputs(s::BAUScenario, crit_load, t0, tf, production_factors)

    pv_kw_series = Float64[]  # actual output (not normalized)

    if any(pv.existing_kw > 0 for pv in s.pvs)  # fill in pv_kw_series
        for pv in s.pvs
            if pv.existing_kw > 0
                if length(pv_kw_series) == 0  # first non-zero existing_kw
                    pv_kw_series = pv.existing_kw * production_factors[pv.name, t0:tf]
                else
                    pv_kw_series += pv.existing_kw * production_factors[pv.name, t0:tf]
                end
            end
        end
    end

    s.outage_outputs.bau_critical_load_met, s.outage_outputs.bau_critical_load_met_time_steps, generator_fuel_use_gal = 
        bau_outage_check(crit_load[t0:tf], pv_kw_series, s.generator, s.settings.time_steps_per_hour)
    return generator_fuel_use_gal
end


"""
    bau_outage_check(critical_loads_kw::AbstractArray, pv_kw_series::AbstractArray, gen::Generator, 
        time_steps_per_hour::Int)

Determine if existing generator and/or PV can meet critical load and for how long.
    
return: (Bool, Int, Float) boolean for if the entire critical load is met, Int for number of time steps the existing 
    generator and PV can meet the critical load, and Float for the gallons of fuel used trying to meet critical load
"""
function bau_outage_check(critical_loads_kw::AbstractArray, pv_kw_series::AbstractArray, gen::Generator, 
    time_steps_per_hour::Int)
    
    generator_fuel_use_gal = 0.0 

    fuel_gal = copy(gen.fuel_avail_gal)
    if gen.existing_kw == 0 && length(pv_kw_series) == 0
        return false, 0, generator_fuel_use_gal
    end

    if gen.existing_kw > 0
        if length(pv_kw_series) == 0
            pv_kw_series = zeros(length(critical_loads_kw))
        end

        for (i, (load, pv)) in enumerate(zip(critical_loads_kw, pv_kw_series))
            unmet = load - pv
            if unmet > 0
                fuel_kwh = (fuel_gal - gen.fuel_intercept_gal_per_hr) / gen.fuel_slope_gal_per_kwh
                gen_avail = minimum([fuel_kwh, gen.existing_kw * (1.0 / time_steps_per_hour)])
                # output = the greater of either the unmet load or available generation based on fuel and the min loading
                gen_output = maximum([minimum([unmet, gen_avail]), gen.min_turn_down_pct * gen.existing_kw])
                fuel_needed = gen.fuel_intercept_gal_per_hr + gen.fuel_slope_gal_per_kwh * gen_output
                fuel_gal -= fuel_needed
                generator_fuel_use_gal += fuel_needed # previous logic: max(min(fuel_needed,fuel_gal), 0)

                # if the generator cannot meet the full load, still assume it runs during the outage
                if gen_output < unmet
                    return false, i-1, generator_fuel_use_gal
                end
            end
        end

    else  # gen.existing_kw = 0 and pv.existing_kw > 0
        for (i, (load, pv)) in enumerate(zip(critical_loads_kw, pv_kw_series))
            unmet = load - pv
            if unmet > 0
                return false, i-1, generator_fuel_use_gal
            end
        end
    end

    return true, length(critical_loads_kw), generator_fuel_use_gal
end
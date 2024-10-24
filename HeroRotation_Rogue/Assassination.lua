--- ============================ HEADER ============================ -- You are using a fork: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl --
--- ======= LOCALIZE =======
-- Addon
local addonName, addonTable = ...
-- HeroDBC
local DBC = HeroDBC.DBC
-- HeroLib
local HL = HeroLib
local Cache = HeroCache
local Unit = HL.Unit
local Player = Unit.Player
local Target = Unit.Target
local Spell = HL.Spell
local MultiSpell = HL.MultiSpell
local Item = HL.Item
local BoolToInt = HL.Utils.BoolToInt
local IntToBool = HL.Utils.IntToBool
local ValueIsInArray = HL.Utils.ValueIsInArray
-- HeroRotation
local HR = HeroRotation
local AoEON = HR.AoEON
local CDsON = HR.CDsON
local Cast = HR.Cast
local CastPooling = HR.CastPooling
local CastQueue = HR.CastQueue
local CastLeftNameplate = HR.CastLeftNameplate
-- Num/Bool Helper Functions
local num = HR.Commons.Everyone.num
local bool = HR.Commons.Everyone.bool
-- Lua
local pairs = pairs
local mathfloor = math.floor
local mathmax = math.max
local mathmin = math.min
-- WoW API
local Delay = C_Timer.After

--- ============================ CONTENT ============================ -- You are using a fork: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl --
--- ======= APL LOCALS =======
-- Commons
local Everyone = HR.Commons.Everyone
local Rogue = HR.Commons.Rogue

-- GUI Settings
local Settings = {
  General = HR.GUISettings.General,
  Commons = HR.GUISettings.APL.Rogue.Commons,
  CommonsDS = HR.GUISettings.APL.Rogue.CommonsDS,
  CommonsOGCD = HR.GUISettings.APL.Rogue.CommonsOGCD,
  Assassination = HR.GUISettings.APL.Rogue.Assassination
}

-- Spells
local S = Spell.Rogue.Assassination

-- Items
local I = Item.Rogue.Assassination
local OnUseExcludeTrinkets = {
  I.BottledFlayedwingToxin:ID(),
  I.ImperfectAscendancySerum:ID(),
  I.TreacherousTransmitter:ID(),
  I.MadQueensMandate:ID()
}

-- Enemies
local MeleeRange, AoERange, TargetInMeleeRange, TargetInAoERange
local Enemies30y, MeleeEnemies10y, MeleeEnemies10yCount, MeleeEnemies5y

-- Rotation Variables
local ShouldReturn
local BleedTickTime, ExsanguinatedBleedTickTime = 2 * Player:SpellHaste(), 1 * Player:SpellHaste()
local ComboPoints, ComboPointsDeficit, ActualComboPoints
local RuptureThreshold, GarroteThreshold, CrimsonTempestThreshold
local PriorityRotation
local AvoidTea, CDSoon, NotPooling, PoisonedBleeds, EnergyRegenCombined, EnergyTimeToMaxCombined, EnergyRegenSaturated, SingleTarget, ScentSaturated
local TrinketSyncSlot = 0
local EnergyIncoming = 0
local EffectiveCPSpend
local DungeonSlice
local InRaid

-- Equipment
local VarTrinketFailures = 0
local function SetTrinketVariables ()
  local T1, T2 = Player:GetTrinketData(OnUseExcludeTrinkets)

  -- If we don't have trinket items, try again in 5 seconds.
  if VarTrinketFailures < 5 and ((T1.ID == 0 or T2.ID == 0) or (T1.SpellID > 0 and not T1.Usable or T2.SpellID > 0 and not T2.Usable)) then
    VarTrinketFailures = VarTrinketFailures + 1
    Delay(5, function()
      SetTrinketVariables()
    end
    )
    return
  end

  TrinketItem1 = T1.Object
  TrinketItem2 = T2.Object

  -- actions.precombat+=/variable,name=trinket_sync_slot,value=1,if=trinket.1.has_stat.any_dps&(!trinket.2.has_stat.any_dps|trinket.1.cooldown.duration>=trinket.2.cooldown.duration)&!trinket.2.is.treacherous_transmitter|trinket.1.is.treacherous_transmitter
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=2,if=trinket.2.has_stat.any_dps&(!trinket.1.has_stat.any_dps|trinket.2.cooldown.duration>trinket.1.cooldown.duration)&!trinket.1.is.treacherous_transmitter|trinket.2.is.treacherous_transmitter
  if TrinketItem1:HasStatAnyDps() and (not TrinketItem2:HasStatAnyDps() or T1.Cooldown >= T2.Cooldown) and T2.ID ~= I.TreacherousTransmitter:ID() or T1.ID == I.TreacherousTransmitter:ID() then
    TrinketSyncSlot = 1
  elseif TrinketItem2:HasStatAnyDps() and (not TrinketItem1:HasStatAnyDps() or T2.Cooldown > T1.Cooldown) and T1.ID ~= I.TreacherousTransmitter:ID() or T2.ID == I.TreacherousTransmitter:ID() then
    TrinketSyncSlot = 2
  else
    TrinketSyncSlot = 0
  end
end
SetTrinketVariables()

HL:RegisterForEvent(function()
  VarTrinketFailures = 0
  SetTrinketVariables()
end, "PLAYER_EQUIPMENT_CHANGED")

HL:RegisterForEvent(function()
  if S.FateboundInevitability:IsAvailable() then
    S.ColdBlood = Spell(456330)
  else
    S.ColdBlood = Spell(382245)
  end
end, "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LOGIN", "PLAYER_TALENT_UPDATE", "PLAYER_SPECIALIZATION_CHANGED")

-- Interrupts
local Interrupts = {
  { S.Blind, "Cast Blind (Interrupt)", function () return true end },
  { S.KidneyShot, "Cast Kidney Shot (Interrupt)", function () return ComboPoints > 0 end }
}

-- Spells Damage
S.Envenom:RegisterDamageFormula(
  -- Envenom DMG Formula:
  --  AP * CP * Env_APCoef * Aura_M * ToxicB_M * DS_M * Mastery_M * Versa_M
  function ()
    return
      -- Attack Power
      Player:AttackPowerDamageMod() *
      -- Combo Points
      ComboPoints *
      -- Envenom AP Coef
      0.22 *
      -- Aura Multiplier (SpellID: 137037)
      1.0 *
      -- Shiv Multiplier
      (Target:DebuffUp(S.ShivDebuff) and 1.3 or 1) *
      -- Deeper Stratagem Multiplier
      (S.DeeperStratagem:IsAvailable() and 1.05 or 1) *
      -- Mastery Finisher Multiplier
      (1 + Player:MasteryPct()/100) *
      -- Versatility Damage Multiplier
      (1 + Player:VersatilityDmgPct() / 100)
  end
)
S.Mutilate:RegisterDamageFormula(
  function ()
    return
      -- Attack Power (MH Factor + OH Factor)
      (Player:AttackPowerDamageMod() + Player:AttackPowerDamageMod(true)) *
      -- Mutilate Coefficient
      0.485 *
      -- Aura Multiplier (SpellID: 137037)
      1.0 *
      -- Versatility Damage Multiplier
      (1 + Player:VersatilityDmgPct()/100)
  end
)

-- Master Assassin Remains Check
local function MasterAssassinAuraUp()
  return Player:BuffRemains(S.MasterAssassinBuff) == 9999
end
local function MasterAssassinRemains ()
  -- Currently stealthed (i.e. Aura)
  if MasterAssassinAuraUp() then
    return Player:GCDRemains() + 3
  end
  -- Broke stealth recently (i.e. Buff)
  return Player:BuffRemains(S.MasterAssassinBuff)
end

-- Improved Garrote Remains Check
local function ImprovedGarroteRemains ()
  -- Currently stealthed (i.e. Aura)
  if Player:BuffUp(S.ImprovedGarroteAura) then
    return Player:GCDRemains() + 3
  end
  -- Broke stealth recently (i.e. Buff)
  return Player:BuffRemains(S.ImprovedGarroteBuff)
end

-- Indiscriminate Carnage Remains Check
local function IndiscriminateCarnageRemains ()
  -- Currently stealthed (i.e. Aura)
  if Player:BuffUp(S.IndiscriminateCarnageAura) then
    return Player:GCDRemains() + 10
  end
  -- Broke stealth recently (i.e. Buff)
  return Player:BuffRemains(S.IndiscriminateCarnageBuff)
end

--- ======= HELPERS =======
-- Check if the Priority Rotation variable should be set
local function UsePriorityRotation()
  if MeleeEnemies10yCount < 2 then
    return false
  elseif Settings.Assassination.UsePriorityRotation == "Always" then
    return true
  elseif Settings.Assassination.UsePriorityRotation == "On Bosses" and Target:IsInBossList() then
    return true
  elseif Settings.Assassination.UsePriorityRotation == "Auto" then
    -- Zul Mythic
    if Player:InstanceDifficulty() == 16 and Target:NPCID() == 138967 then
      return true
    end
  end

  return false
end

-- actions+=/variable,name=in_cooldowns,value=dot.deathmark.ticking|dot.kingsbane.ticking|debuff.shiv.up
local function InCooldowns()
  return Target:DebuffUp(S.Deathmark) or Target:DebuffUp(S.Kingsbane) or Target:DebuffUp(S.ShivDebuff)
end
-- actions+=/variable,name=clip_envenom,value=buff.envenom.up&buff.envenom.remains<=1
local function ClipEnvenom()
  return Player:BuffUp(S.Envenom) and Player:BuffRemains(S.Envenom) <= 1.5
end
-- actions+=/variable,name=upper_limit_energy,value=energy.pct>=(50-10*talent.vicious_venoms.rank) note: 50 to 47 to account for delay
local function UpperLimitEnergy()
  return Player:EnergyPercentage() >= (47 - 10 * S.ViciousVenoms:TalentRank())
end
-- actions+=/variable,name=avoid_tea,value=energy>40+50+5*talent.vicious_venoms.rank
local function AvoidTeaVar()
  -- Check if the AvoidTea setting is enabled
  if Settings.Assassination.AvoidTeaEnabled then
    -- Return true if energy is greater than the threshold
    return Player:Energy() > (40 + 50 + 5 * S.ViciousVenoms:TalentRank())
  else
    -- If the setting is disabled, always return true
    return true
  end
end
-- actions+=/variable,name=cd_soon,value=cooldown.kingsbane.remains<3&!cooldown.kingsbane.ready
local function CDSoonVar()
  return S.Kingsbane:CooldownRemains() < 3 and not S.Kingsbane:IsCastable()
end
-- actions+=/variable,name=not_pooling,value=variable.in_cooldowns|!variable.cd_soon&variable.avoid_tea&buff.darkest_night.up|!variable.cd_soon&variable.avoid_tea&variable.clip_envenom|variable.upper_limit_energy|fight_remains<=20
local function NotPoolingVar()
  if InCooldowns() or (not CDSoon and AvoidTea and Player:BuffUp(S.DarkestNight)) or (not CDSoon and AvoidTea and ClipEnvenom()) or UpperLimitEnergy() or HL.BossFilteredFightRemains("<=", 20) then
      return true
  end
  return false
end


-- actions.dot=variable,name=scent_effective_max_stacks,value=(spell_targets.fan_of_knives*talent.scent_of_blood.rank*2)>?20
-- actions.dot+=/variable,name=scent_saturation,value=buff.scent_of_blood.stack>=variable.scent_effective_max_stacks
local function ScentSaturatedVar()
  if not S.ScentOfBlood:IsAvailable() then
    return true
  end
  return Player:BuffStack(S.ScentOfBloodBuff) >= mathmin(20, S.ScentOfBlood:TalentRank() * 2 * MeleeEnemies10yCount)
end

local function HasEdgeCase()
  return Player:BuffUp(S.FateboundCoinHeads) and Player:BuffUp(S.FateboundCoinTails)
end

-- Custom Override for Handling 4pc Pandemics
local function IsDebuffRefreshable(TargetUnit, Spell, PandemicThreshold)
  local PandemicThreshold = PandemicThreshold or Spell:PandemicThreshold()
  --if Tier284pcEquipped and TargetUnit:DebuffUp(S.Vendetta) then
  --  PandemicThreshold = PandemicThreshold * 0.5
  --end
  return TargetUnit:DebuffRefreshable(Spell, PandemicThreshold)
end

-- Handle CastLeftNameplate Suggestions for DoT Spells
local function SuggestCycleDoT(DoTSpell, DoTEvaluation, DoTMinTTD, Enemies)
  -- Prefer melee cycle units
  local BestUnit, BestUnitTTD = nil, DoTMinTTD
  local TargetGUID = Target:GUID()
  for _, CycleUnit in pairs(Enemies) do
    if CycleUnit:GUID() ~= TargetGUID and Everyone.UnitIsCycleValid(CycleUnit, BestUnitTTD, -CycleUnit:DebuffRemains(DoTSpell))
    and DoTEvaluation(CycleUnit) then
      BestUnit, BestUnitTTD = CycleUnit, CycleUnit:TimeToDie()
    end
  end
  if BestUnit then
    CastLeftNameplate(BestUnit, DoTSpell)
  -- Check ranged units next, if the RangedMultiDoT option is enabled
  elseif Settings.Commons.RangedMultiDoT then
    BestUnit, BestUnitTTD = nil, DoTMinTTD
    for _, CycleUnit in pairs(MeleeEnemies10y) do
      if CycleUnit:GUID() ~= TargetGUID and Everyone.UnitIsCycleValid(CycleUnit, BestUnitTTD, -CycleUnit:DebuffRemains(DoTSpell))
      and DoTEvaluation(CycleUnit) then
        BestUnit, BestUnitTTD = CycleUnit, CycleUnit:TimeToDie()
      end
    end
    if BestUnit then
      CastLeftNameplate(BestUnit, DoTSpell)
    end
  end
end

-- Target If handler
-- Mode is "min", "max", or "first"
-- ModeEval the target_if condition (function with a target as param)
-- IfEval the condition on the resulting target (function with a target as param)
local function CheckTargetIfTarget(Mode, ModeEvaluation, IfEvaluation)
  -- First mode: Only check target if necessary
  local TargetsModeValue = ModeEvaluation(Target)
  if Mode == "first" and TargetsModeValue ~= 0 then
    return Target
  end

  local BestUnit, BestValue = nil, 0
  local function RunTargetIfCycler(Enemies)
    for _, CycleUnit in pairs(Enemies) do
      local ValueForUnit = ModeEvaluation(CycleUnit)
      if not BestUnit and Mode == "first" then
        if ValueForUnit ~= 0 then
          BestUnit, BestValue = CycleUnit, ValueForUnit
        end
      elseif Mode == "min" then
        if not BestUnit or ValueForUnit < BestValue then
          BestUnit, BestValue = CycleUnit, ValueForUnit
        end
      elseif Mode == "max" then
        if not BestUnit or ValueForUnit > BestValue then
          BestUnit, BestValue = CycleUnit, ValueForUnit
        end
      end
      -- Same mode value, prefer longer TTD
      if BestUnit and ValueForUnit == BestValue and CycleUnit:TimeToDie() > BestUnit:TimeToDie() then
        BestUnit, BestValue = CycleUnit, ValueForUnit
      end
    end
  end

  -- Prefer melee cycle units over ranged
  RunTargetIfCycler(MeleeEnemies5y)
  if Settings.Commons.RangedMultiDoT then
    RunTargetIfCycler(MeleeEnemies10y)
  end
  -- Prefer current target if equal mode value results to prevent "flickering"
  if BestUnit and BestValue == TargetsModeValue and IfEvaluation(Target) then
    return Target
  end
  if BestUnit and IfEvaluation(BestUnit) then
    return BestUnit
  end
  return nil
end

local baseDamageMap = {
  [584] = 2414811,
  [587] = 2489600,
  [590] = 2566685,
  [593] = 2646114,
  [597] = 2755894,
  [600] = 2841156,
  [603] = 2929054,
  [606] = 3019638,
  [610] = 3144769,
  [613] = 3241983,
  [616] = 3342181,
  [619] = 3445456,
  [623] = 3588099,
  [626] = 3698923,
  [629] = 3813138,
  [632] = 3930865,
  [636] = 4093467,
  [639] = 4219779
}
-- Functions for calculating trinket damage
local function GetMadQueensBaseDamage()
  -- Get the item level of Mad Queen's Mandate
  local itemLevel = I.MadQueensMandate:Level()
  return baseDamageMap[itemLevel] or 0
end

local function CalculateMadQueensDamage()
  local currentHealth = Target:Health()
  local maxHealth = Target:MaxHealth()

  if currentHealth == 0 or not currentHealth then return 0 end
  
  -- Get base damage based on item level
  local baseDamage = GetMadQueensBaseDamage()
  -- Calculate damage scaling with missing health
  local healthFactor = 1 + (math.min((maxHealth - currentHealth) / maxHealth, 0.5) / 2) -- 1% per 2% missing health, capped at 50%
  return baseDamage * healthFactor
end
--- ======= ACTION LISTS =======
-- # Stealthed
local function Stealthed (ReturnSpellOnly, ForceStealth)
  -- actions.stealthed=pool_resource,for_next=1
  -- actions.stealthed+=/ambush,if=!debuff.deathstalkers_mark.up&talent.deathstalkers_mark
  if (S.Ambush:IsReady() or ForceStealth) and (Target:DebuffDown(S.DeathStalkersMarkDebuff) and Player:BuffRemains(S.DarkestNightBuff) < 10) and S.DeathStalkersMark:IsAvailable() then
    if ReturnSpellOnly then
      return S.Ambush
    else
      if Cast(S.Ambush, nil, nil, not TargetInMeleeRange) then return "Cast Ambush Stealthed" end
    end
  end

  -- actions.stealthed+=/shiv,if=talent.kingsbane&(dot.kingsbane.ticking)&(!debuff.shiv.up&debuff.shiv.remains<1)&buff.envenom.up
  if S.Kingsbane:IsAvailable() and Player:BuffUp(S.Envenom) then
    if S.Shiv:IsCastable() and (Target:DebuffUp(S.Kingsbane)) and (not Target:DebuffUp(S.ShivDebuff) or (Target:DebuffRemains(S.ShivDebuff) < 1 and Target:DebuffUp(S.ShivDebuff))) then
      if ReturnSpellOnly then
        return S.Shiv
      else
        if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Stealth Kingsbane)" end
      end
    end
  end
  -- actions.stealthed+=/cold_blood,if=effective_combo_points>=variable.effective_spend_cp&!buff.edge_case.up&cooldown.deathmark.remains>10&!buff.darkest_night.up&(dot.kingsbane.ticking&buff.envenom.remains<=3|buff.master_assassin_aura.up&variable.single_target)
  if (S.ColdBlood:IsCastable() and not Player:BuffUp(S.ColdBlood)) and ComboPoints >= EffectiveCPSpend 
    and not HasEdgeCase() and S.Deathmark:CooldownRemains() > 10 and Player:BuffDown(S.DarkestNightBuff) 
    and ((Target:DebuffUp(S.Kingsbane) and Player:BuffRemains(S.Envenom) <= 3) or (MasterAssassinAuraUp() and SingleTarget)) then
    if Cast(S.ColdBlood, Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood) then 
      return "Cast Cold Blood (Stealthed)" 
    end
  end
  -- actions.stealthed+=/envenom,if=effective_combo_points>=variable.effective_spend_cp&dot.kingsbane.ticking&buff.envenom.remains<=3&(debuff.deathstalkers_mark.up|buff.edge_case.up|buff.cold_blood.up)
  -- actions.stealthed+=/envenom,if=effective_combo_points>=variable.effective_spend_cp&buff.master_assassin_aura.up&variable.single_target&(debuff.deathstalkers_mark.up|buff.edge_case.up|buff.cold_blood.up)
  if S.Envenom:IsCastable() and ComboPoints >= EffectiveCPSpend then
    if Target:DebuffUp(S.Kingsbane) and Player:BuffRemains(S.Envenom) <= 3 and (Target:DebuffUp(S.DeathStalkersMarkDebuff) or HasEdgeCase() or Player:BuffUp(S.ColdBlood)) then
      if ReturnSpellOnly then
        return S.Envenom
      else
        if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom (Stealth Kingsbane)" end
      end
    end
    if SingleTarget and MasterAssassinAuraUp() and (Target:DebuffUp(S.DeathStalkersMarkDebuff) or HasEdgeCase() or Player:BuffUp(S.ColdBlood)) then
      if ReturnSpellOnly then
        return S.Envenom
      else
        if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom (Master Assassin)" end
      end
    end
  end

  -- # Rupture during Indiscriminate Carnage
  -- actions.stealthed+=/rupture,target_if=effective_combo_points>=variable.effective_spend_cp&buff.indiscriminate_carnage.up&(refreshable||(buff.indiscriminate_carnage.up&active_dot.rupture<spell_targets.fan_of_knives&!variable.single_target))&(!variable.regen_saturated|!variable.scent_saturation|!dot.rupture.ticking)&target.time_to_die-remains>15
  if S.Rupture:IsCastable() or ForceStealth then
    local function RuptureTargetIfFunc(TargetUnit)
      return TargetUnit:DebuffRemains(S.Rupture)
    end
    local function RuptureIfFunc(TargetUnit)
      return ComboPoints >= EffectiveCPSpend 
        and Player:BuffUp(S.IndiscriminateCarnageBuff) 
        and (IsDebuffRefreshable(TargetUnit, S.Rupture, RuptureThreshold) or (IndiscriminateCarnageRemains() > 0.5 and S.Rupture:AuraActiveCount() < MeleeEnemies10yCount and not SingleTarget))
        and (not EnergyRegenSaturated or not ScentSaturated or TargetUnit:DebuffDown(S.Rupture))
        and (TargetUnit:FilteredTimeToDie(">", 15, -TargetUnit:DebuffRemains(S.Rupture)) or TargetUnit:TimeToDieIsNotValid())
    end
    -- Handle AoE logic with Indiscriminate Carnage and check the setting for CastLeftNameplate usage
    if HR.AoEON() then
      local TargetIfUnit = CheckTargetIfTarget("min", RuptureTargetIfFunc, RuptureIfFunc)
      -- Spread Rupture with or without CastLeftNameplate based on settings
      if TargetIfUnit and IndiscriminateCarnageRemains() > 0.5 then
        if Settings.Assassination.NoLeftNameplatewhenICupRupture then
          -- Simplified logic: No CastLeftNameplate, still ensure main target gets Rupture
          if RuptureIfFunc(TargetIfUnit) then
            if ReturnSpellOnly then
              return S.Rupture
          else
            if Cast(S.Rupture, nil, nil, not TargetInMeleeRange) then return "Cast Rupture (Stealth Indiscriminate Carnage)" end
            end
          end
      else
        -- Original behavior: use CastLeftNameplate for other targets
        if TargetIfUnit:GUID() ~= Target:GUID() then
          CastLeftNameplate(TargetIfUnit, S.Rupture) end
        end
      end
    end
  end
  -- actions.stealthed+=/garrote,target_if=min:remains,if=stealthed.improved_garrote&(remains<12|pmultiplier<=1|(buff.indiscriminate_carnage.up&active_dot.garrote<spell_targets.fan_of_knives&combo_points.deficit>=1))&!variable.single_target&target.time_to_die-remains>2
  -- actions.stealthed+=/garrote,if=stealthed.improved_garrote&(pmultiplier<=1|refreshable)&combo_points.deficit>=1+2*talent.shrouded_suffocation
  if (S.Garrote:IsCastable() and ImprovedGarroteRemains() > 0.5) or ForceStealth then
    local function GarroteTargetIfFunc(TargetUnit)
      return TargetUnit:DebuffRemains(S.Garrote)
    end
    local function GarroteIfFunc(TargetUnit)
      return (TargetUnit:PMultiplier(S.Garrote) <= 1 or TargetUnit:DebuffRemains(S.Garrote) < 12
      or (IndiscriminateCarnageRemains() > 0.5 and S.Garrote:AuraActiveCount() < MeleeEnemies10yCount and ComboPointsDeficit >= 1)) and not SingleTarget
      and (TargetUnit:FilteredTimeToDie(">", 2, -TargetUnit:DebuffRemains(S.Garrote)) or TargetUnit:TimeToDieIsNotValid())
    end
    -- Handle AoE logic with Indiscriminate Carnage and check the setting for CastLeftNameplate usage
    if HR.AoEON() then
        local TargetIfUnit = CheckTargetIfTarget("min", GarroteTargetIfFunc, GarroteIfFunc)
        -- Spread Garrote with or without CastLeftNameplate based on settings
        if TargetIfUnit and IndiscriminateCarnageRemains() > 0.5 then
          if Settings.Assassination.NoLeftNameplatewhenICupGarrote then
              -- If NoLeftNameplatewhenICupGarrote is enabled, apply Garrote only on the main target
              if GarroteIfFunc(TargetIfUnit) then
                  if ReturnSpellOnly then
                      return S.Garrote
                  else
                      if Cast(S.Garrote, nil, nil, not TargetInMeleeRange) then 
                          return "Cast Garrote (Improved Garrote)"
                      end
                  end
              end
          else
              -- If NoLeftNameplatewhenICupGarrote is disabled, use CastLeftNameplate on other targets
              if TargetIfUnit:GUID() ~= Target:GUID() then
                  CastLeftNameplate(TargetIfUnit, S.Garrote)
              end
          end
      end
    end
    if ComboPointsDeficit >= 1 + 2 * num(S.ShroudedSuffocation:IsAvailable()) and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold)) then
      if ReturnSpellOnly then
        return S.Garrote
      else
        if Cast(S.Garrote, nil, nil, not TargetInMeleeRange) then return "Cast Garrote (Improved Garrote Low CP)" end
      end
    end
  end
end

-- # Stealth Macros
-- This returns a table with the original Stealth spell and the result of the Stealthed action list as if the applicable buff was present
local function StealthMacro (StealthSpell)
  -- Fetch the predicted ability to use after the stealth spell, a number of abilities require stealth to be castable
  -- so fake stealth to allow them to be evaluated
  local MacroAbility = Stealthed(true, true)

  -- Handle StealthMacro GUI options
  -- If false, just suggest them as off-GCD and bail out of the macro functionality
  if StealthSpell:ID() == S.Vanish:ID() then
    if DungeonSlice and Settings.Assassination.VanishalwaysasOffGCD then
      -- In Dungeon: Always show regular Vanish, no split icon
      if Cast(S.Vanish, Settings.Assassination.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
      return false
    else
      -- Not in Dungeon: Use existing logic
      if not Settings.Assassination.StealthMacro.Vanish or not MacroAbility then
        if Cast(S.Vanish, Settings.CommonsOGCD.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
        return false
      end
    end
  elseif StealthSpell:ID() == S.Shadowmeld:ID() and (not Settings.Assassination.StealthMacro.Shadowmeld or not MacroAbility) then
    if Cast(S.Shadowmeld, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Shadowmeld" end
    return false
  end

  local MacroTable = {StealthSpell, MacroAbility}

  ShouldReturn = CastQueue(unpack(MacroTable))
  if ShouldReturn then return "| " .. MacroTable[2]:Name() end
  return false
end

-- # Cooldowns
local function CDs ()

  if not HR.CDsON() then
    return
  end

  -- actions.cds=variable,name=deathmark_ma_condition,value=!talent.master_assassin.enabled|dot.garrote.ticking
  -- actions.cds+=/variable,name=deathmark_kingsbane_condition,value=!talent.kingsbane|cooldown.kingsbane.remains<=2
  -- actions.cds+=/variable,name=deathmark_condition,value=!stealthed.rogue&buff.slice_and_dice.remains>5&dot.rupture.ticking&buff.envenom.up&!debuff.deathmark.up&variable.deathmark_ma_condition&variable.deathmark_kingsbane_condition
  local DeathmarkMACondition = not S.MasterAssassin:IsAvailable() or Target:DebuffUp(S.Garrote)
  local DeathmarkKingsbaneCondition = not S.Kingsbane:IsAvailable() or S.Kingsbane:CooldownRemains() <= 2
  local DeathmarkCondition = not Player:StealthUp(true, false) and Player:BuffRemains(S.SliceandDice) > 5 and Target:DebuffUp(S.Rupture) and Player:BuffUp(S.Envenom) and not S.Deathmark:AnyDebuffUp()
    and DeathmarkMACondition and DeathmarkKingsbaneCondition

  -- actions.cds+=/call_action_list,name=items
  -- actions.items=variable,name=base_trinket_condition,value=dot.rupture.ticking&cooldown.deathmark.remains<2|dot.deathmark.ticking|fight_remains<=22
  if Settings.Commons.Enabled.Trinkets then
    -- actions.items+=/use_item,name=treacherous_transmitter,use_off_gcd=1,if=variable.base_trinket_condition
    if I.TreacherousTransmitter:IsEquippedAndReady() then
      if (Target:DebuffUp(S.Rupture) and S.Deathmark:CooldownRemains() <= 2 or Target:DebuffUp(S.Deathmark) or (HL.BossFilteredFightRemains("<", 22) and InRaid)) then
        if Cast(I.TreacherousTransmitter, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Treacherous Transmitter"; end
      end
    end
    -- actions.items+=/use_item,name=mad_queens_mandate,if=cooldown.deathmark.remains>=30&!dot.deathmark.ticking|fight_remains<=3
    if I.MadQueensMandate:IsEquippedAndReady() then
      if (S.Deathmark:CooldownRemains() >= 30 and Target:DebuffDown(S.Deathmark) or HL.BossFilteredFightRemains("<=", 3)) then
        if Cast(I.MadQueensMandate, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
          return "Mad Queen's Mandate";
        end
      end
    end
    -- Reset Check 
    if I.MadQueensMandate:IsEquippedAndReady() then
      local calculatedDamage = CalculateMadQueensDamage()
      -- Only cast the trinket if the calculated damage exceeds the target's current health
      if calculatedDamage >= Target:Health() and not Target:IsDummy() then
          if Cast(I.MadQueensMandate, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
              return "Mad Queen's Mandate";
          end
      end
    end
    -- actions.items+=/use_item,name=imperfect_ascendancy_serum,use_off_gcd=1,if=variable.base_trinket_condition
    if I.ImperfectAscendancySerum:IsEquippedAndReady() then
      if (Target:DebuffUp(S.Rupture) and S.Deathmark:CooldownRemains() <= 2 or (HL.BossFilteredFightRemains("<", 22) and InRaid)) then
        if Cast(I.ImperfectAscendancySerum, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Imperfect Ascendancy Serum"; end
      end
    end

    -- actions.items+=/use_items,slots=trinket1,if=(variable.trinket_sync_slot=1&(debuff.deathmark.up|fight_remains<=20)|(variable.trinket_sync_slot=2&(!trinket.2.cooldown.ready&dot.kingsbane.ticking|!debuff.deathmark.up&cooldown.deathmark.remains>20&dot.kingsbane.ticking))|!variable.trinket_sync_slot)
    -- actions.items+=/use_items,slots=trinket2,if=(variable.trinket_sync_slot=2&(debuff.deathmark.up|fight_remains<=20)|(variable.trinket_sync_slot=1&(!trinket.1.cooldown.ready|!debuff.deathmark.up&cooldown.deathmark.remains>20))|!variable.trinket_sync_slot)
    if TrinketItem1:IsReady() then
      if not Player:IsItemBlacklisted(TrinketItem1) and not ValueIsInArray(OnUseExcludeTrinkets, TrinketItem1:ID())
        and (TrinketSyncSlot == 1 and (S.Deathmark:AnyDebuffUp() or (HL.BossFilteredFightRemains("<", 20) and InRaid)) or (TrinketSyncSlot == 2 and (not TrinketItem2:IsReady() and Target:DebuffUp(S.Kingsbane) or not S.Deathmark:AnyDebuffUp() and S.Deathmark:CooldownRemains() > 20 and Target:DebuffUp(S.Kingsbane))) or TrinketSyncSlot == 0) then
        if Cast(TrinketItem1, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
         return "Trinket 1";
        end
      end
    end

    if TrinketItem2:IsReady() then
      if not Player:IsItemBlacklisted(TrinketItem2) and not ValueIsInArray(OnUseExcludeTrinkets, TrinketItem2:ID())
        and (TrinketSyncSlot == 2 and (S.Deathmark:AnyDebuffUp() or (HL.BossFilteredFightRemains("<", 20) and InRaid)) or (TrinketSyncSlot == 1 and (not TrinketItem1:IsReady() and Target:DebuffUp(S.Kingsbane) or not S.Deathmark:AnyDebuffUp() and S.Deathmark:CooldownRemains() > 20 and Target:DebuffUp(S.Kingsbane))) or TrinketSyncSlot == 0) then
        if Cast(TrinketItem2, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
          return "Trinket 2";
        end
      end
    end
  end

  -- actions.cds+=/invoke_external_buff,name=power_infusion,if=dot.deathmark.ticking
  -- Note: We don't handle external buffs.

  -- actions.cds+=/deathmark,if=(variable.deathmark_condition&target.time_to_die>=10)|fight_remains<=20
  if S.Deathmark:IsCastable() then
    if (DeathmarkCondition and Target:TimeToDie() >= 10) or (HL.BossFilteredFightRemains("<=", 20) and InRaid) then
      if Cast(S.Deathmark, Settings.Assassination.OffGCDasOffGCD.Deathmark) then return "Cast Deathmark" end
    end
  end

  -- Base conditions for Shiv included in CD section
  -- # Check for Applicable Shiv usage
  -- actions.cds+=/call_action_list,name=shiv
  -- actions.shiv=variable,name=shiv_condition,value=!debuff.shiv.up&dot.garrote.ticking&dot.rupture.ticking extra check to fulfill 100% uptime on Shiv during dmg windows
  local ShivCondition = (not Target:DebuffUp(S.ShivDebuff) or (Target:DebuffRemains(S.ShivDebuff) < 1 and Target:DebuffUp(S.ShivDebuff))) and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
  -- actions.shiv+=/variable,name=shiv_kingsbane_condition,value=talent.kingsbane&buff.envenom.up&variable.shiv_condition
  local ShivKingsbaneCondition = S.Kingsbane:IsAvailable() and Player:BuffUp(S.Envenom) and ShivCondition
  
  if S.Shiv:IsCastable() then
    local FightRemains = HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8)
    
    -- # Shiv for aoe with Arterial Precision
    -- actions.shiv+=/shiv,if=talent.arterial_precision&variable.shiv_condition&spell_targets.fan_of_knives>=4&dot.crimson_tempest.ticking|fight_remains<=charges*8 note: exlcuded Ovi'nax
    if S.ArterialPrecision:IsAvailable() and ShivCondition and MeleeEnemies10yCount >= 4 and Target:DebuffUp(S.CrimsonTempest) and not Target:NPCID() == 214506 then
      if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Arterial Precision AoE)" end
    end
    -- # Shiv cases for Kingsbane
    -- actions.shiv+=/shiv,if=!talent.lightweight_shiv.enabled&variable.shiv_kingsbane_condition&(dot.kingsbane.ticking&dot.kingsbane.remains<8|!dot.kingsbane.ticking&cooldown.kingsbane.remains>=20)&(!talent.crimson_tempest.enabled|variable.single_target|dot.crimson_tempest.ticking)|fight_remains<=charges*8
    if ShivKingsbaneCondition then
      if not S.LightweightShiv:IsAvailable() and (Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) < 8 or not Target:DebuffUp(S.Kingsbane) and S.Kingsbane:CooldownRemains() >= 20) and (not S.CrimsonTempest:IsAvailable() or SingleTarget or Target:DebuffUp(S.CrimsonTempest)) then
         if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Kingsbane)" end
      end
      -- actions.shiv+=/shiv,if=talent.lightweight_shiv.enabled&variable.shiv_kingsbane_condition&(dot.kingsbane.ticking|cooldown.kingsbane.remains<=1)|fight_remains<=charges*8 
      if S.LightweightShiv:IsAvailable() and (Target:DebuffUp(S.Kingsbane) or S.Kingsbane:CooldownRemains() <= 1) then
        if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Kingsbane Lightweight)" end
      end
    end
    -- # Fallback shiv for arterial during deathmark
    -- actions.shiv+=/shiv,if=talent.arterial_precision&variable.shiv_condition&debuff.deathmark.up|fight_remains<=charges*8
    if S.ArterialPrecision:IsAvailable() and ShivCondition and S.Deathmark:AnyDebuffUp() then
      if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Arterial Precision Deathmark)" end
    end
    -- # Fallback if no special cases apply
    -- actions.shiv+=/shiv,if=(!talent.kingsbane&!talent.arterial_precision&variable.shiv_condition&(!talent.crimson_tempest.enabled|variable.single_target|dot.crimson_tempest.ticking))|(fight_remains<=charges*8&!debuff.shiv.up)
    if not S.Kingsbane:IsAvailable() and not S.ArterialPrecision:IsAvailable() and ShivCondition and (not S.CrimsonTempest:IsAvailable() or SingleTarget or Target:DebuffUp(S.CrimsonTempest)) then
      if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Fallback)" end
    end
    -- actions.shiv+=/shiv,if=fight_remains<=cooldown.shiv.charges*8
    if FightRemains and InRaid then
      if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (End of Fight)" end
    end
  end

  -- actions.cds+=/kingsbane,if=(debuff.shiv.up|cooldown.shiv.remains<6)&buff.envenom.up&(cooldown.deathmark.remains>=45|dot.deathmark.ticking)|fight_remains<=15 Note: based on TC Channel 45 Sec instead of 50; Added DS check so you may use KB alone even when DM is ready. Added Target:DebuffUp(S.Deathmark) so you may always use KB once DM is on the target (Env updatime may be lost due to pooling or mechanics)
  if S.Kingsbane:IsCastable() then
    if (Target:DebuffUp(S.ShivDebuff) or S.Shiv:CooldownRemains() < 6) and (Player:BuffUp(S.Envenom) or Target:DebuffUp(S.Deathmark)) and (S.Deathmark:CooldownRemains() >= 45 or DungeonSlice or Target:DebuffUp(S.Deathmark)) or (HL.BossFilteredFightRemains("<=", 15) and InRaid) then
      if Cast(S.Kingsbane, Settings.Assassination.GCDasOffGCD.Kingsbane) then return "Cast Kingsbane" end
    end
  end

  -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&(dot.kingsbane.ticking|debuff.shiv.remains>=4)|spell_targets.fan_of_knives>=4&debuff.shiv.remains>=6|fight_remains<=cooldown.thistle_tea.charges*6
  if S.ThistleTea:IsCastable() then
    if not Player:BuffUp(S.ThistleTea) and ((Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.ShivDebuff) >= 4) or MeleeEnemies10yCount >= 4 and Target:DebuffRemains(S.ShivDebuff) >= 6 or (HL.BossFilteredFightRemains("<", S.ThistleTea:Charges() * 6) and InRaid)) then
      if HR.Cast(S.ThistleTea, Settings.CommonsOGCD.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea" end
    end
  end

  -- MiscCDs here
  -- actions.cds+=/call_action_list,name=misc_cds
  if Settings.Commons.Enabled.Potions then
    local PotionSelected = Everyone.PotionSelected()
    if PotionSelected and PotionSelected:IsReady() and (Player:BloodlustUp() or HL.BossFilteredFightRemains("<", 30) or S.Deathmark:AnyDebuffUp()) then
      if Cast(PotionSelected, nil, Settings.CommonsDS.DisplayStyle.Potions) then return "Cast Potion"; end
    end
  end

  -- Racials
  if S.Deathmark:AnyDebuffUp() and (not ShouldReturn or Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then
    -- actions.misc_cds+=/blood_fury,if=debuff.deathmark.up
    if S.BloodFury:IsCastable() then
      if Cast(S.BloodFury, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Blood Fury" end
    end
    -- actions.misc_cds+=/berserking,if=debuff.deathmark.up
    if S.Berserking:IsCastable() then
      if Cast(S.Berserking, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Berserking" end
    end
    -- actions.misc_cds+=/fireblood,if=debuff.deathmark.up
    if S.Fireblood:IsCastable() then
      if Cast(S.Fireblood, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Fireblood" end
    end
    -- actions.misc_cds+=/ancestral_call,if=(!talent.kingsbane&debuff.deathmark.up&debuff.shiv.up)|(talent.kingsbane&debuff.deathmark.up&dot.kingsbane.ticking&dot.kingsbane.remains<8)
    if S.AncestralCall:IsCastable() then
      if (not S.Kingsbane:IsAvailable() and Target:DebuffUp(S.ShivDebuff))
        or (Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) < 8) then
        if Cast(S.AncestralCall, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Ancestral Call" end
      end
    end
  end

  -- # Vanish Handling here
  -- local function Vanish ()
  -- actions.cds+=/call_action_list,name=vanish,if=!stealthed.all&master_assassin_remains=0
  if not Player:StealthUp(true, true) and MasterAssassinRemains() <= 0 then

    -- # Vanish to fish for Fateful Ending if possible
    -- actions.vanish+=/vanish,if=!buff.fatebound_lucky_coin.up&(buff.fatebound_coin_tails.stack>=5|buff.fatebound_coin_heads.stack>=5)
    if S.Vanish:IsCastable() and Player:BuffDown(S.FateboundLuckyCoin) and (Player:BuffStack(S.FateboundCoinTails) >= 5 or Player:BuffStack(S.FateboundCoinHeads) >= 5) then
      ShouldReturn = StealthMacro(S.Vanish)
      if ShouldReturn then return "Cast Vanish (Fateful Ending Fish)" .. ShouldReturn end
    end

    -- # Vanish to spread Garrote during Deathmark without Indiscriminate Carnage
    -- actions.vanish+=/vanish,if=!talent.master_assassin&!talent.indiscriminate_carnage&talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&(debuff.deathmark.up|cooldown.deathmark.remains<4)&combo_points.deficit>=(spell_targets.fan_of_knives>?4)
    if S.Vanish:IsCastable() and not S.MasterAssassin:IsAvailable() and not S.IndiscriminateCarnage:IsAvailable() and S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp() and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold)) and (Target:DebuffUp(S.Deathmark) or S.Deathmark:CooldownRemains() < 4) and ComboPointsDeficit >= mathmin(MeleeEnemies10yCount, 4) then
      ShouldReturn = StealthMacro(S.Vanish)
      if ShouldReturn then return "Cast Vanish Garrote Deathmark (No Carnage)" .. ShouldReturn end
    end

    -- # Vanish for cleaving Garrotes with Indiscriminate Carnage
    -- actions.vanish+=/vanish,if=talent.indiscriminate_carnage&talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&spell_targets.fan_of_knives>2&(target.time_to_die-remains>15|raid_event.adds.in>20)
    if S.Vanish:IsCastable() and S.IndiscriminateCarnage:IsAvailable() and S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp() and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold)) and MeleeEnemies10yCount > 2 and Target:TimeToDie() > 15 then
      ShouldReturn = StealthMacro(S.Vanish)
      if ShouldReturn then return "Cast Vanish (Garrote Carnage)" .. ShouldReturn end
    end

    -- # Vanish fallback for Master Assassin
    --actions.vanish+=/vanish,if=talent.master_assassin&dot.garrote.remains>3&debuff.deathmark.up&dot.kingsbane.remains<=6+3*talent.subterfuge.rank&(debuff.shiv.up|debuff.deathmark.remains<4) extra check for target debuff up to prevent suggestion, added 0.5 for more leeway
    if S.Vanish:IsCastable() and S.MasterAssassin:IsAvailable() and Target:DebuffRemains(S.Garrote) > 0 and Target:DebuffUp(S.Deathmark) and Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) <= 6.5 + 3 * S.Subterfuge:TalentRank() and (Target:DebuffUp(S.ShivDebuff) or Target:DebuffRemains(S.Deathmark) < 4) then
      ShouldReturn = StealthMacro(S.Vanish)
      if ShouldReturn then return "Cast Vanish (Master Assassin)" .. ShouldReturn end
    end

    -- # Vanish fallback for Improved Garrote during Deathmark if no add waves are expected
    --actions.vanish+=/vanish,if=talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&(debuff.deathmark.up|cooldown.deathmark.remains<4)&raid_event.adds.in>30 note: added not S.MasterAssassin:IsAvailable() check as it defaults to this here although you should follow the line above)
    if S.Vanish:IsCastable() and not S.MasterAssassin:IsAvailable() and S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp() and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold)) and ((Target:DebuffUp(S.Deathmark) and not S.Kingsbane:IsCastable()) or (S.Deathmark:CooldownRemains() < 4 and InRaid)) then
      ShouldReturn = StealthMacro(S.Vanish)
      if ShouldReturn then return "Cast Vanish (Improved Garrote during Deathmark)" .. ShouldReturn end
    end
  end
  -- # Cold Blood with similar conditions to Envenom, avoiding munching Edge Case
  -- actions.cds+=/cold_blood,if=!buff.edge_case.up&cooldown.deathmark.remains>10&!buff.darkest_night.up&combo_points>=variable.effective_spend_cp&(variable.not_pooling|debuff.amplifying_poison.stack>=20|!variable.single_target)&!buff.vanish.up&(!cooldown.kingsbane.up|!variable.single_target)&!cooldown.deathmark.up Note: !buff.edge_case.up does not exist
  if (S.ColdBlood:IsCastable() and not Player:BuffUp(S.ColdBlood)) and not HasEdgeCase() and S.Deathmark:CooldownRemains() > 10 and Player:BuffDown(S.DarkestNightBuff) and ActualComboPoints >= EffectiveCPSpend and (NotPooling or (Target:DebuffStack(S.AmplifyingPoisonDebuff) + Target:DebuffStack(S.AmplifyingPoisonDebuffDeathmark)) >= 20 or not SingleTarget) and Player:BuffDown(Rogue.VanishBuffSpell()) and (not S.Kingsbane:CooldownUp() or not SingleTarget) and not S.Deathmark:CooldownUp() then
    if Cast(S.ColdBlood, Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood) then return "Cast Cold Blood" end
  end
end

local function CoreDot()
  -- Maintain Garrote
  -- actions.core_dot=/garrote,if=combo_points.deficit>=1&(pmultiplier<=1)&refreshable&target.time_to_die-remains>12 note: testing InRaid or Vanish not castable in order to see if it works as I imagine with Master Assassin
  if S.Garrote:IsCastable() and ComboPointsDeficit >= 1 and Target:PMultiplier(S.Garrote) <= 1 
    and IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold) and (not S.Vanish:IsCastable() or not InRaid)
    and (Target:FilteredTimeToDie(">", 12, -Target:DebuffRemains(S.Garrote)) or Target:TimeToDieIsNotValid()) then
    if CastPooling(S.Garrote, nil, not TargetInMeleeRange) then return "Cast Garrote (Core)" end
  end

  -- Maintain Rupture unless darkest night is up
  -- actions.core_dot+=/rupture,if=combo_points>=variable.effective_spend_cp&(pmultiplier<=1)&refreshable&target.time_to_die-remains>(4+(talent.dashing_scoundrel*5)+(variable.regen_saturated*6))&(!buff.darkest_night.up|talent.caustic_spatter&!debuff.caustic_spatter.up)
  if S.Rupture:IsCastable() and ActualComboPoints >= EffectiveCPSpend and Target:PMultiplier(S.Rupture) <= 1 
    and IsDebuffRefreshable(Target, S.Rupture, RuptureThreshold) and (Player:BuffDown(S.DarkestNightBuff) or S.CausticSpatter:IsAvailable() and Target:DebuffDown(S.CausticSpatterDebuff)) then
    local RuptureDurationThreshold = 4 + (S.DashingScoundrel:IsAvailable() and 5 or 0) + (EnergyRegenSaturated and 6 or 0)
    if Target:FilteredTimeToDie(">", RuptureDurationThreshold, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid() then
      if CastPooling(S.Rupture, nil, not TargetInMeleeRange) then return "Cast Rupture (Core)" end
    end
  end

  -- # Backup-line to Garrote at full CP if Debuff is gone
  -- actions.core_dot+=/garrote,if=combo_points.deficit=0&!dot.garrote.ticking&dot.rupture.ticking&variable.single_target&!(buff.envenom.up&buff.envenom.remains<=1.5)
  if S.Garrote:IsCastable() and ComboPointsDeficit == 0 and not Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture) and SingleTarget and not (Player:BuffUp(S.Envenom) and Player:BuffRemains(S.Envenom) <= 1.5)
     and (Target:FilteredTimeToDie(">", 4, -Target:DebuffRemains(S.Garrote)) or Target:TimeToDieIsNotValid()) then
     if Cast(S.Garrote, nil, nil, not TargetInMeleeRange) then return "Garrote (MaxCP)" end
  end

  return false
end

-- # Damage over time abilities
local function AoeDot ()
  -- # Crimson Tempest on 2+ Targets if we have enough energy regen note: variable.dot_finisher_condition = combo_points>=variable.effective_spend_cp&(pmultiplier<=1)
  -- crimson_tempest,target_if=min:remains,if=spell_targets>=2&variable.dot_finisher_condition&refreshable&target.time_to_die-remains>6&!buff.darkest_night.up note: 10 sec check to not allow CT spam when chainpulling
  if HR.AoEON() and S.CrimsonTempest:IsCastable() and MeleeEnemies10yCount >= 2 and Player:BuffDown(S.DarkestNightBuff) and ActualComboPoints >= EffectiveCPSpend and (S.CrimsonTempest:TimeSinceLastCast() > 10 or S.CrimsonTempest:TimeSinceLastCast() == 0) then
    local function EvaluateCrimsonTempestTarget(TargetUnit)
      return TargetUnit:DebuffRemains(S.CrimsonTempest)
    end
    local function CrimsonTempestIfFunc(TargetUnit)
      return IsDebuffRefreshable(TargetUnit, S.CrimsonTempest, CrimsonTempestThreshold)
           and TargetUnit:PMultiplier(S.CrimsonTempest) <= 1
           and (TargetUnit:FilteredTimeToDie(">", 6, -TargetUnit:DebuffRemains(S.CrimsonTempest)) or TargetUnit:TimeToDieIsNotValid())  
    end
    if HR.AoEON() then
      local BestUnit = CheckTargetIfTarget("min", EvaluateCrimsonTempestTarget, CrimsonTempestIfFunc)
      if BestUnit then
        if Cast(S.CrimsonTempest, nil, nil, not TargetInAoERange) then return "Cast Crimson Tempest (AoE)" end
      end
    end
  end
  -- # Garrote upkeep, also uses it in AoE to reach energy saturation
  -- actions.aoe_dot+=/garrote,cycle_targets=1,if=combo_points.deficit>=1&(pmultiplier<=1)&refreshable&!variable.regen_saturated&target.time_to_die-remains>12
  if S.Garrote:IsCastable() and ComboPointsDeficit >= 1 then
    local function Evaluate_Garrote_Target(TargetUnit)
      return IsDebuffRefreshable(TargetUnit, S.Garrote, GarroteThreshold) and TargetUnit:PMultiplier(S.Garrote) <= 1
    end
    if HR.AoEON() and not EnergyRegenSaturated and S.Kingsbane:CooldownRemains() < 46 and S.Deathmark:CooldownRemains() < 104 then
      SuggestCycleDoT(S.Garrote, Evaluate_Garrote_Target, 12, MeleeEnemies5y)
    end
  end

  -- # Rupture upkeep, also uses it in AoE to reach energy or Scent of Blood saturation and spread Serrated Bone Spike
  -- actions.aoe_dot+=/rupture,cycle_targets=1,if=variable.dot_finisher_condition&refreshable&(!dot.kingsbane.ticking|buff.cold_blood.up)&(!variable.regen_saturated&(talent.scent_of_blood.rank=2|talent.scent_of_blood.rank<=1&(buff.indiscriminate_carnage.up|target.time_to_die-remains>15)))&target.time_to_die-remains>(7+(talent.dashing_scoundrel*5)+(variable.regen_saturated*6))&!buff.darkest_night.up
  if S.Rupture:IsCastable() and ActualComboPoints >= EffectiveCPSpend and Player:BuffDown(S.DarkestNightBuff) then
    local function Evaluate_Rupture_Target(TargetUnit)
      return IsDebuffRefreshable(TargetUnit, S.Rupture, RuptureThreshold) and TargetUnit:PMultiplier(S.Rupture) <= 1
       and (not TargetUnit:DebuffUp(S.Kingsbane) or Player:BuffUp(S.ColdBlood))
       and (not EnergyRegenSaturated and (S.ScentOfBlood:TalentRank() == 2 or S.ScentOfBlood:TalentRank() <= 1 and (IndiscriminateCarnageRemains() > 0.5  or (TargetUnit:FilteredTimeToDie(">", 15, -TargetUnit:DebuffRemains(S.Rupture))))) or TargetUnit:TimeToDieIsNotValid())
       and (TargetUnit:FilteredTimeToDie(">", (7 + (S.DashingScoundrel:TalentRank() * 5) + (EnergyRegenSaturated and 6 or 0)), -TargetUnit:DebuffRemains(S.Rupture)) or TargetUnit:TimeToDieIsNotValid())
    end
    -- AoE and cycle logic
    if HR.AoEON() and S.Kingsbane:CooldownRemains() < 46 and S.Deathmark:CooldownRemains() < 104 then
        SuggestCycleDoT(S.Rupture, Evaluate_Rupture_Target, 15, MeleeEnemies5y)
    end
  end
  -- actions.aoe_dot+=/rupture,cycle_targets=1,if=variable.dot_finisher_condition&refreshable&(!dot.kingsbane.ticking|buff.cold_blood.up)&variable.regen_saturated&!variable.scent_saturation&target.time_to_die-remains>19&!buff.darkest_night.up
  if S.Rupture:IsCastable() and ActualComboPoints >= EffectiveCPSpend and Player:BuffDown(S.DarkestNightBuff) then
    local function Evaluate_Rupture_Target(TargetUnit)
      return IsDebuffRefreshable(TargetUnit, S.Rupture, RuptureThreshold) and TargetUnit:PMultiplier(S.Rupture) <= 1
        and (not TargetUnit:DebuffUp(S.Kingsbane) or Player:BuffUp(S.ColdBlood))
        and EnergyRegenSaturated and not ScentSaturated and TargetUnit:FilteredTimeToDie(">", 19, -TargetUnit:DebuffRemains(S.Rupture))
    end
    -- AoE and cycle logic
    if HR.AoEON() and S.Kingsbane:CooldownRemains() < 46 and S.Deathmark:CooldownRemains() < 104 then
        SuggestCycleDoT(S.Rupture, Evaluate_Rupture_Target, 19, MeleeEnemies5y)
    end
  end
  -- actions.aoe_dot+=/garrote,if=refreshable&combo_points.deficit>=1&(pmultiplier<=1|remains<=tick_time&spell_targets.fan_of_knives>=3)&(remains<=tick_time*2&spell_targets.fan_of_knives>=3)&(target.time_to_die-remains)>4&master_assassin_remains=0
  if S.Garrote:IsCastable() and IsDebuffRefreshable(Target, S.Garrote, GarroteThreshold) and ComboPointsDeficit >= 1 and MasterAssassinRemains() <= 0
    and (Target:PMultiplier(S.Garrote) <= 1 or Target:DebuffRemains(S.Garrote) <= BleedTickTime and MeleeEnemies10yCount >= 3)
    and (Target:DebuffRemains(S.Garrote) <= BleedTickTime * 2 and MeleeEnemies10yCount >= 3)
    and (Target:FilteredTimeToDie(">", 4, -Target:DebuffRemains(S.Garrote)) or Target:TimeToDieIsNotValid()) then
    if Cast(S.Garrote, nil, nil, not TargetInMeleeRange) then return "Garrote (Fallback)" end
  end

  return false
end

-- # Direct damage abilities
local function Direct ()
  -- actions.direct=envenom,if=!buff.darkest_night.up&combo_points>=variable.effective_spend_cp&(variable.not_pooling|debuff.amplifying_poison.stack>=20|!variable.single_target)&!buff.vanish.up
  if S.Envenom:IsCastable() and Player:BuffDown(S.DarkestNightBuff) and ActualComboPoints >= EffectiveCPSpend and (NotPooling or (Target:DebuffStack(S.AmplifyingPoisonDebuff) + Target:DebuffStack(S.AmplifyingPoisonDebuffDeathmark)) >= 20 or not SingleTarget) and Player:BuffDown(Rogue.VanishBuffSpell()) then
    if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom 1" end
  end

  -- actions.direct=envenom,if=buff.darkest_night.up&effective_combo_points>=cp_max_spend
  if S.Envenom:IsCastable() and Player:BuffUp(S.DarkestNightBuff) and ComboPoints >= Rogue.CPMaxSpend() then
    if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom 2" end
  end

  --- !!!! ---
  -- # Maintain Caustic Spatter
  -- actions.direct+=/variable,name=use_caustic_filler,value=talent.caustic_spatter&dot.rupture.ticking&(!debuff.caustic_spatter.up|debuff.caustic_spatter.remains<=2)&combo_points.deficit>=1&!variable.single_target&target.time_to_die>2
  local UseCausticFiller = S.CausticSpatter:IsAvailable() and Target:DebuffUp(S.Rupture) and (Target:DebuffDown(S.CausticSpatterDebuff) or Target:DebuffRemains(S.CausticSpatterDebuff) <= 2) and ComboPointsDeficit >= 1 and not SingleTarget and Target:TimeToDie() > 2
  -- actions.direct+=/ambush,if=variable.use_caustic_filler
  if UseCausticFiller and (S.Ambush:IsReady() or S.AmbushOverride:IsReady()) and (Player:StealthUp(true, true) or Player:BuffUp(S.BlindsideBuff)) then
    if Cast(S.Ambush, nil, nil, not TargetInMeleeRange) then return "Cast Ambush (Caustic)" end
  end
  -- actions.direct+=/mutilate,if=variable.use_caustic_filler
  if UseCausticFiller and S.Mutilate:IsCastable() then
    if Cast(S.Mutilate, nil, nil, not TargetInMeleeRange) then return "Cast Mutilate (Caustic)" end
  end

  --- !!!! --- TODO
  -- actions.direct+=/variable,name=use_filler,value=combo_points<=variable.effective_spend_cp&!variable.cd_soon|variable.not_pooling|!variable.single_target
  -- Note: This is used in all following fillers, so we just return false if not true and won't consider these. changed to <= to < as you dont want to mut at 5 or fill when at 5
  if not ((ActualComboPoints < EffectiveCPSpend and not CDSoon) or NotPooling or not SingleTarget or (Player:BuffUp(S.DarkestNightBuff) and Rogue.CPMaxSpend() and AvoidTea)) then
    return false
  end
  -- # Fan of Knives at 3+ targets, 2+ targets as Deathstalker with Thrown Precision, or with clear the witnesses active
  -- actions.direct+=/fan_of_knives,if=variable.use_filler&!priority_rotation&(spell_targets.fan_of_knives>=3-(talent.momentum_of_despair&talent.thrown_precision)|buff.clear_the_witnesses.up&!talent.vicious_venoms)
  if S.FanofKnives:IsCastable() then
    if HR.AoEON() and not PriorityRotation and (MeleeEnemies10yCount >= 3 - num(S.MomentumOfDespair:IsAvailable() and S.ThrownPrecision:IsAvailable()) or Player:BuffUp(S.ClearTheWitnessesBuff) and not S.ViciousVenoms:IsAvailable()) then
      if CastPooling(S.FanofKnives, nil, not TargetInAoERange) then return "Cast Fan of Knives (AOE or CTW)" end
    end
    -- # Fan of Knives to apply poisons if inactive on any target (or any bleeding targets with priority rotation) at 3T, or 2T as Deathstalker with Thrown Precision
    -- actions.direct+=/fan_of_knives,target_if=!dot.deadly_poison_dot.ticking&(!priority_rotation|dot.garrote.ticking|dot.rupture.ticking),if=variable.use_filler&spell_targets.fan_of_knives>=3-(talent.momentum_of_despair&talent.thrown_precision)
    if HR.AoEON() and MeleeEnemies10yCount >= 3 - num(S.MomentumOfDespair:IsAvailable() and S.ThrownPrecision:IsAvailable()) then
      for _, CycleUnit in pairs(MeleeEnemies10y) do
        if not CycleUnit:DebuffUp(S.DeadlyPoisonDebuff, true) and (not PriorityRotation or CycleUnit:DebuffUp(S.Garrote) or CycleUnit:DebuffUp(S.Rupture)) then
          if CastPooling(S.FanofKnives, nil, not TargetInAoERange) then return "Cast Fan of Knives (DP Refresh)" end
        end
      end
    end
  end

  -- # Ambush on Blindside/Subterfuge. Do not use Ambush from stealth during Kingsbane & Deathmark.
  -- actions.direct+=/ambush,if=variable.use_filler&(buff.blindside.up|stealthed.rogue)&(!dot.kingsbane.ticking|debuff.deathmark.down|buff.blindside.up)
  if (S.Ambush:IsReady() or S.AmbushOverride:IsReady()) and (Player:BuffUp(S.BlindsideBuff) or Player:StealthUp(true, false)) and (Target:DebuffDown(S.Kingsbane) or Target:DebuffDown(S.Deathmark) or Player:BuffUp(S.BlindsideBuff)) then
      if CastPooling(S.Ambush, nil, not TargetInMeleeRange) then return "Cast Ambush" end
  end

  -- actions.direct+=/mutilate,target_if=!dot.deadly_poison_dot.ticking&!debuff.amplifying_poison.up,if=variable.use_filler&spell_targets.fan_of_knives=2
  if S.Mutilate:IsCastable() and MeleeEnemies10yCount == 2 and Target:DebuffDown(S.DeadlyPoisonDebuff, true) and Target:DebuffDown(S.AmplifyingPoisonDebuff, true) then
    local TargetGUID = Target:GUID()
    for _, CycleUnit in pairs(MeleeEnemies5y) do
      -- Note: The APL does not do this due to target_if mechanics, but since we are cycling we should check to see if the unit has a bleed
      if CycleUnit:GUID() ~= TargetGUID and (CycleUnit:DebuffUp(S.Garrote) or CycleUnit:DebuffUp(S.Rupture)) and not CycleUnit:DebuffUp(S.DeadlyPoisonDebuff, true) and not CycleUnit:DebuffUp(S.AmplifyingPoisonDebuff, true) then
        CastLeftNameplate(CycleUnit, S.Mutilate)
        break
      end
    end
  end
  -- actions.direct+=/mutilate,if=variable.use_filler
  if S.Mutilate:IsCastable() then
    if CastPooling(S.Mutilate, nil, not TargetInMeleeRange) then return "Cast Mutilate" end
  end

  return false
end

--- ======= MAIN =======
local function APL ()
  -- Enemies Update
  MeleeRange = 5
  AoERange = 10
  TargetInMeleeRange = Target:IsInMeleeRange(MeleeRange)
  TargetInAoERange = Target:IsInMeleeRange(AoERange)
  if AoEON() then
    Enemies30y = Player:GetEnemiesInRange(30) -- Poisoned Knife & Serrated Bone Spike
    MeleeEnemies10y = Player:GetEnemiesInMeleeRange(AoERange) -- Fan of Knives & Crimson Tempest
    MeleeEnemies10yCount = #MeleeEnemies10y
    MeleeEnemies5y = Player:GetEnemiesInMeleeRange(MeleeRange) -- Melee cycle
  else
    Enemies30y = {}
    MeleeEnemies10y = {}
    MeleeEnemies10yCount = 1
    MeleeEnemies5y = {}
  end
  -- Rotation Variables Update
  BleedTickTime, ExsanguinatedBleedTickTime = 2 * Player:SpellHaste(), 1 * Player:SpellHaste()
  ComboPoints = Rogue.EffectiveComboPoints(Player:ComboPoints())
  ActualComboPoints = Player:ComboPoints()
  ComboPointsDeficit = Player:ComboPointsMax() - ComboPoints
  RuptureThreshold = (4 + ComboPoints * 4) * 0.3
  GarroteThreshold = 18 * 0.3
  CrimsonTempestThreshold = (4 + ComboPoints * 2) * 0.3
  PriorityRotation = UsePriorityRotation()
  EffectiveCPSpend = mathmax(Rogue.CPMaxSpend() - 2, 5 * num(S.HandOfFate:IsAvailable()))
  DungeonSlice = Player:IsInParty() and Player:IsInDungeonArea() and not Player:IsInRaid()
  InRaid = Player:IsInRaid() and not Player:IsInDungeonArea()
  

  -- Defensives
  -- Crimson Vial
  ShouldReturn = Rogue.CrimsonVial()
  if ShouldReturn then return ShouldReturn end

  -- Poisons
  Rogue.Poisons()

  -- Bottled Flayedwing Toxin
  if I.BottledFlayedwingToxin:IsEquippedAndReady() and Player:BuffDown(S.FlayedwingToxin) then
    if Cast(I.BottledFlayedwingToxin, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
      return "Bottle Of Flayedwing Toxin";
    end
  end

  -- Out of Combat
  if not Player:AffectingCombat() then
    -- actions.precombat=apply_poison
    -- Note: Handled just above.
    -- actions.precombat+=/flask
    -- actions.precombat+=/augmentation
    -- actions.precombat+=/food
    -- actions.precombat+=/snapshot_stats
    -- actions.precombat+=/stealth
    if not Player:BuffUp(Rogue.VanishBuffSpell()) then
      ShouldReturn = Rogue.Stealth(Rogue.StealthSpell())
      if ShouldReturn then return ShouldReturn end
    end
    -- Opener
    if Everyone.TargetIsValid() then
      -- actions.precombat+=/slice_and_dice,precombat_seconds=1
      if not Player:BuffUp(S.SliceandDice) then
        if S.SliceandDice:IsReady() and ComboPoints >= 2 then
          if Cast(S.SliceandDice) then return "Cast Slice and Dice" end
        end
      end
    end
  end

  if Everyone.TargetIsValid() then
    -- Interrupts
    ShouldReturn = Everyone.Interrupt(S.Kick, Settings.CommonsDS.DisplayStyle.Interrupts, Interrupts)
    if ShouldReturn then return ShouldReturn end

    PoisonedBleeds = Rogue.PoisonedBleeds()
    -- TODO: Make this match the updated code version
    EnergyRegenCombined = Player:EnergyRegen() + PoisonedBleeds * 6 / (2 * Player:SpellHaste())
    EnergyTimeToMaxCombined = Player:EnergyDeficit() / EnergyRegenCombined
    -- actions+=/variable,name=energy_incoming,op=reset
    EnergyIncoming = 0
    -- actions+=/cycling_variable,name=energy_incoming,op=add,value=dot.rupture.remains>target.time_to_die&target.time_to_die<=20&talent.venomous_wounds
    if S.VenomousWounds:IsAvailable() then
      for _, Unit in pairs(Enemies30y) do
        if Unit:DebuffUp(S.Rupture) and Unit:TimeToDie() <= 20 and Unit:DebuffRemains(S.Rupture) > Unit:TimeToDie() then
          EnergyIncoming = EnergyIncoming + 1
        end
      end
    end
    -- actions+=/variable,name=regen_saturated,value=(energy.regen_combined>35)|(variable.energy_incoming>=1&talent.caustic_spatter)
    EnergyRegenSaturated = (EnergyRegenCombined > 35) or (EnergyIncoming >= 1 and S.CausticSpatter:IsAvailable())
    AvoidTea = AvoidTeaVar()
    CDSoon = CDSoonVar()
    NotPooling = NotPoolingVar()
    ScentSaturated = ScentSaturatedVar()

    -- actions=/stealth
    -- actions+=/variable,name=single_target,value=spell_targets.fan_of_knives<2
    SingleTarget = MeleeEnemies10yCount < 2

    -- actions+=/call_action_list,name=stealthed,if=stealthed.rogue|stealthed.improved_garrote|master_assassin_remains>0
    if Player:StealthUp(true, false) or ImprovedGarroteRemains() > 0 or MasterAssassinRemains() > 0 then
      ShouldReturn = Stealthed()
      if ShouldReturn then return ShouldReturn .. " (Stealthed)" end
    end

    -- actions+=/call_action_list,name=cds
    ShouldReturn = CDs()
    if ShouldReturn then return ShouldReturn end

    if TargetInAoERange then
      --- !!!! ---
      -- Special fallback Poisoned Knife Out of Range [EnergyCap] or [PoisonRefresh]
      -- Only if we are about to cap energy, not stealthed, and completely out of range
      --- !!!! ---
      if S.PoisonedKnife:IsCastable() and Target:IsInRange(30) and not Player:StealthUp(true, true)
        and MeleeEnemies10yCount == 0 and Player:EnergyTimeToMax() <= Player:GCD() * 1.5 then
        if Cast(S.PoisonedKnife) then return "Cast Poisoned Knife" end
      end
    end

    -- actions+=/call_action_list,name=core_dot
    ShouldReturn = CoreDot()
    if ShouldReturn then return ShouldReturn end
    -- actions+=/call_action_list,name=aoe_dot,if=!variable.single_target
    if HR.AoEON() and not SingleTarget then
      ShouldReturn = AoeDot()
      if ShouldReturn then return ShouldReturn end
    end

    -- actions+=/call_action_list,name=direct
    ShouldReturn = Direct()
    if ShouldReturn then return ShouldReturn end

    -- Racials
    if HR.CDsON() then
      -- actions+=/arcane_torrent,if=energy.deficit>=15+energy.regen_combined
      if S.ArcaneTorrent:IsCastable() and Player:EnergyDeficit() >= 15 + EnergyRegenCombined then
        if Cast(S.ArcaneTorrent, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Arcane Torrent" end
      end
      -- actions+=/arcane_pulse
      if S.ArcanePulse:IsCastable() then
        if Cast(S.ArcanePulse, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Arcane Pulse" end
      end
      -- actions+=/lights_judgment
      if S.LightsJudgment:IsCastable() then
        if Cast(S.LightsJudgment, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Lights Judgment" end
      end
      -- actions+=/bag_of_tricks
      if S.BagofTricks:IsCastable() then
        if Cast(S.BagofTricks, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Bag of Tricks" end
      end
    end
    -- Trick to take in consideration the Recovery Setting
    if S.Mutilate:IsCastable() or S.Ambush:IsReady() or S.AmbushOverride:IsReady() then
      if Cast(S.PoolEnergy) then return "Normal Pooling" end
    end
  end
end

local function Init ()
  S.Deathmark:RegisterAuraTracking()
  S.Garrote:RegisterAuraTracking()
  S.Rupture:RegisterAuraTracking()
  S.Kingsbane:RegisterAuraTracking()
  S.Shiv:RegisterAuraTracking()

  HR.Print("You are using a fork [Version 3.0]: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl")
end

HR.SetAPL(259, APL, Init)

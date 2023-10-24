--- Localize Vars
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
-- HeroRotation
local HR = HeroRotation
local AoEON = HR.AoEON
local CDsON = HR.CDsON
-- Num/Bool Helper Functions
local num = HR.Commons.Everyone.num
local bool = HR.Commons.Everyone.bool
-- Lua
local pairs = pairs
local tableinsert = table.insert
local mathmin = math.min
local mathmax = math.max
local mathabs = math.abs

--- APL Local Vars
-- Commons
local Everyone = HR.Commons.Everyone
local Rogue = HR.Commons.Rogue
-- Define S/I for spell and item arrays
local S = Spell.Rogue.Subtlety
local I = Item.Rogue.Subtlety

-- Create table to exclude above trinkets from On Use function
local OnUseExcludes = {
  I.ManicGrieftorch:ID(),
  I.BeaconToTheBeyond:ID(),
  I.MirrorOfFracturedTomorrows:ID(),
  I.AshesOfTheEmbersoul:ID(),
  I.WitherBarksBranch:ID(),
  I.BandolierOfTwistedBlades:ID(),
}

-- Rotation Var
local MeleeRange, AoERange, TargetInMeleeRange, TargetInAoERange
local Enemies30y, MeleeEnemies10y, MeleeEnemies10yCount, MeleeEnemies5y
local ShouldReturn; -- Used to get the return string
local PoolingAbility, PoolingEnergy, PoolingFinisher; -- Used to store an ability we might want to pool for as a fallback in the current situation
local RuptureThreshold, RuptureDMGThreshold
local EffectiveComboPoints, ComboPoints, ComboPointsDeficit, StealthEnergyRequired
local PriorityRotation

S.Eviscerate:RegisterDamageFormula(
  -- Eviscerate DMG Formula (Pre-Mitigation):
  --- Player Modifier
    -- AP * CP * EviscR1_APCoef * Aura_M * NS_M * DS_M * DSh_M * SoD_M * Finality_M * Mastery_M * Versa_M
  --- Target Modifier
    -- EviscR2_M * Sinful_M
  function ()
    return
      --- Player Modifier
        -- Attack Power
        Player:AttackPowerDamageMod() *
        -- Combo Points
        EffectiveComboPoints *
        -- Eviscerate R1 AP Coef
        0.176 *
        -- Aura Multiplier (SpellID: 137035)
        1.21 *
        -- Nightstalker Multiplier
        (S.Nightstalker:IsAvailable() and Player:StealthUp(true, false) and 1.08 or 1) *
        -- Deeper Stratagem Multiplier
        (S.DeeperStratagem:IsAvailable() and 1.05 or 1) *
        -- Shadow Dance Multiplier
        (S.DarkShadow:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) and 1.3 or 1) *
        -- Symbols of Death Multiplier
        (Player:BuffUp(S.SymbolsofDeath) and 1.1 or 1) *
        -- Finality Multiplier
        (Player:BuffUp(S.FinalityEviscerateBuff) and 1.3 or 1) *
        -- Mastery Finisher Multiplier
        (1 + Player:MasteryPct() / 100) *
        -- Versatility Damage Multiplier
        (1 + Player:VersatilityDmgPct() / 100) *
      --- Target Modifier
        -- Eviscerate R2 Multiplier
        (Target:DebuffUp(S.FindWeaknessDebuff) and 1.5 or 1)
  end
)

S.Rupture:RegisterPMultiplier(
  function ()
    return Player:BuffUp(S.FinalityRuptureBuff) and 1.3 or 1
  end
)

-- GUI Settings
local Settings = {
  General = HR.GUISettings.General,
  Commons = HR.GUISettings.APL.Rogue.Commons,
  Commons2 = HR.GUISettings.APL.Rogue.Commons2,
  Subtlety = HR.GUISettings.APL.Rogue.Subtlety
}

local function SetPoolingAbility(PoolingSpell, EnergyThreshold)
  if not PoolingAbility then
    PoolingAbility = PoolingSpell
    PoolingEnergy = EnergyThreshold or 0
  end
end

local function SetPoolingFinisher(PoolingSpell)
  if not PoolingFinisher then
    PoolingFinisher = PoolingSpell
  end
end

local function MayBurnShadowDance()
  if Settings.Subtlety.BurnShadowDance == "On Bosses not in Dungeons" and Player:IsInDungeonArea() then
    return false
  elseif Settings.Subtlety.BurnShadowDance ~= "Always" and not Target:IsInBossList() then
    return false
  else
    return true
  end
end

local function UsePriorityRotation()
  if MeleeEnemies10yCount < 2 then
    return false
  elseif Settings.Commons.UsePriorityRotation == "Always" then
    return true
  elseif Settings.Commons.UsePriorityRotation == "On Bosses" and Target:IsInBossList() then
    return true
  elseif Settings.Commons.UsePriorityRotation == "Auto" then
    -- Zul Mythic
    if Player:InstanceDifficulty() == 16 and Target:NPCID() == 138967 then
      return true
    -- Council of Blood
    elseif Target:NPCID() == 166969 or Target:NPCID() == 166971 or Target:NPCID() == 166970 then
      return true
    -- Anduin (Remnant of a Fallen King/Monstrous Soul)
    elseif Target:NPCID() == 183463 or Target:NPCID() == 183671 then
      return true
    end
  end

  return false
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
    HR.CastLeftNameplate(BestUnit, DoTSpell)
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
      HR.CastLeftNameplate(BestUnit, DoTSpell)
    end
  end
end

-- APL Action Lists (and Variables)
local function Stealth_Threshold ()
  -- actions+=/variable,name=stealth_threshold,value=25+talent.vigor.enabled*20+talent.master_of_shadows.enabled*20+talent.shadow_focus.enabled*25+talent.alacrity.enabled*20+25*(spell_targets.shuriken_storm>=4)
  return 25 + num(S.Vigor:IsAvailable()) * 20 + num(S.MasterofShadows:IsAvailable()) * 20 + num(S.ShadowFocus:IsAvailable()) * 25 + num(S.Alacrity:IsAvailable()) * 20 + num(MeleeEnemies10yCount >= 4) * 25
end
local function ShD_Threshold ()
  -- actions.stealth_cds=variable,name=shd_threshold,value=cooldown.shadow_dance.charges_fractional>=0.75+talent.shadow_dance
  return S.ShadowDance:ChargesFractional() >= 0.75 + BoolToInt(S.ShadowDanceTalent:IsAvailable())
end
local function ShD_Combo_Points ()
  -- actions.stealth_cds+=/variable,name=shd_combo_points,value=combo_points<=1
  -- actions.stealth_cds+=/variable,name=shd_combo_points,value=combo_points.deficit>=3
  return ComboPoints <= 1 or ComboPointsDeficit >= 3
end
local function SnD_Condition ()
  -- actions+=/variable,name=snd_condition,value=buff.slice_and_dice.up|spell_targets.shuriken_storm>=cp_max_spend
  return Player:BuffUp(S.SliceandDice) or MeleeEnemies10yCount >= Rogue.CPMaxSpend()
end
local function Skip_Rupture (ShadowDanceBuff)
  -- actions.finish+=/variable,name=skip_rupture,value=buff.thistle_tea.up&spell_targets.shuriken_storm=1|buff.shadow_dance.up&(spell_targets.shuriken_storm=1|dot.rupture.ticking&spell_targets.shuriken_storm>=2)
  return Player:BuffUp(S.ThistleTea) and MeleeEnemies10yCount == 1
    or ShadowDanceBuff and (MeleeEnemies10yCount == 1 or Target:DebuffUp(S.Rupture) and MeleeEnemies10yCount >= 2) or Target:NPCID() == 202969 or Target:NPCID() == 203230 or Target:NPCID() == 202824 or Target:NPCID() == 202971 or Target:NPCID() == 201738 or Target:NPCID() == 202814
end
local function Rotten_Threshold ()
  -- variable,name=rotten_threshold,value=!buff.the_rotten.up|!set_bonus.tier30_2pc (in the APL its called "name=rotten")
  return not Player:BuffUp(S.TheRottenBuff) or not Player:HasTier(30, 2)
end
local function Secret_Condition(ShadowDanceBuff, PremeditationBuff)
  -- actions.finish=variable,name=secret_condition,value=buff.shadow_dance.up&(buff.danse_macabre.stack>=3|!talent.danse_macabre)&(!buff.premeditation.up|spell_targets.shuriken_storm!=2)
  return ShadowDanceBuff and (Player:BuffStack(S.DanseMacabreBuff) >= 3 or not S.DanseMacabre:IsAvailable())
      and (not PremeditationBuff or MeleeEnemies10yCount ~= 2)
end
local function Used_For_Danse(Spell)
  return Player:BuffUp(S.ShadowDanceBuff) and Spell:TimeSinceLastCast() < S.ShadowDance:TimeSinceLastCast()
end
local function Trinket_Conditions ()
  -- actions.cds=variable,name=trinket_conditions,value=(!equipped.witherbarks_branch&!equipped.ashes_of_the_embersoul|!equipped.witherbarks_branch&trinket.witherbarks_branch.cooldown.remains<=8|equipped.witherbarks_branch&trinket.witherbarks_branch.cooldown.remains<=8|equipped.bandolier_of_twisted_blades|talent.invigorating_shadowdust)
  return (not I.WitherBarksBranch:IsEquippedAndReady() and not I.AshesOfTheEmbersoul:IsEquippedAndReady()) or 
         (not I.WitherBarksBranch:IsEquippedAndReady() and I.WitherBarksBranch:CooldownRemains() <= 8) or 
         (I.WitherBarksBranch:IsEquippedAndReady() and I.WitherBarksBranch:CooldownRemains() <= 8) or 
         I.BandolierOfTwistedBlades:IsEquippedAndReady() or S.InvigoratingShadowdust:IsAvailable()
end

-- # Finishers
-- ReturnSpellOnly and StealthSpell parameters are to Predict Finisher in case of Stealth Macros
local function Finish (ReturnSpellOnly, StealthSpell)
  local ShadowDanceBuff = Player:BuffUp(S.ShadowDanceBuff)
  local ShadowDanceBuffRemains = Player:BuffRemains(S.ShadowDanceBuff)
  local SymbolsofDeathBuffRemains = Player:BuffRemains(S.SymbolsofDeath)
  local FinishComboPoints = ComboPoints

  -- State changes based on predicted Stealth casts
  local PremeditationBuff = StealthSpell or Player:BuffUp(S.PremeditationBuff)
  if StealthSpell and StealthSpell:ID() == S.ShadowDance:ID() then
    ShadowDanceBuff = true
    ShadowDanceBuffRemains = 8 + S.ImprovedShadowDance:TalentRank()
    if S.TheFirstDance:IsAvailable() then
      FinishComboPoints = mathmin(Player:ComboPointsMax(), ComboPoints + 4)
    end
    if Player:HasTier(30, 2) then
      SymbolsofDeathBuffRemains = mathmax(SymbolsofDeathBuffRemains, 6)
    end
  end

  -- actions.finish+=/rupture,if=!dot.rupture.ticking&target.time_to_die-remains>6
  if (not Player:BuffUp(S.ShadowDanceBuff) or PriorityRotation) and S.Rupture:IsCastable() then
    if TargetInMeleeRange
      and (Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid())
      and Rogue.CanDoTUnit(Target, RuptureDMGThreshold) then
    -- Added condition: Check if Rupture is not ticking
      if not Target:DebuffUp(S.Rupture) then
        if ReturnSpellOnly then
          return S.Rupture
          else
          if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture 3" end
          SetPoolingFinisher(S.Rupture)
        end
      end
    end
  end

    if S.SliceandDice:IsCastable() and HL.FilteredFightRemains(MeleeEnemies10y, ">", Player:BuffRemains(S.SliceandDice)) then
      -- actions.finish+=/variable,name=premed_snd_condition,value=talent.premeditation.enabled&spell_targets.shuriken_storm<5
      local premed_snd_condition = S.Premeditation:IsAvailable() and MeleeEnemies10yCount < 5
      -- actions.finish+=/slice_and_dice,if=!stealthed.all&!variable.premed_snd_condition&spell_targets.shuriken_storm<6&!buff.shadow_dance.up&buff.slice_and_dice.remains<fight_remains&refreshable
      if not Player:StealthUp(true, true) and not premed_snd_condition and MeleeEnemies10yCount < 6 and not ShadowDanceBuff
         and Player:BuffRemains(S.SliceandDice) < (1 + FinishComboPoints * 1.8) then
         if ReturnSpellOnly then
            return S.SliceandDice
         else
            if S.SliceandDice:IsReady() and HR.Cast(S.SliceandDice) then return "Cast Slice and Dice (Premeditation)" end
            SetPoolingFinisher(S.SliceandDice)
         end
      end
    end

  local SkipRupture = Skip_Rupture(ShadowDanceBuff)
  -- actions.finish+=/rupture,if=(!variable.skip_rupture|variable.priority_rotation)&target.time_to_die-remains>6&(refreshable&(dot.rupture.pmultiplier<=1|buff.finality_rupture.up)|remains<=2) // (if not Player:BuffUp(S.ShadowDanceBuff) instead of Skip_Rupture as it does not work correctly.)
  if (not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture or PriorityRotation) and S.Rupture:IsCastable() then
    if TargetInMeleeRange
      and (Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid())
      and Rogue.CanDoTUnit(Target, RuptureDMGThreshold)
      and Target:DebuffRefreshable(S.Rupture, RuptureThreshold) and (Pmultiplier(S.Rupture) <= 1 or Player:BuffUp(S.FinalityRupture)) or Target:DebuffRemains(S.Rupture) <= 2) then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture 1" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- actions.finish+=/rupture,if=!variable.skip_rupture&buff.finality_rupture.up&cooldown.shadow_dance.remains<12&cooldown.shadow_dance.charges_fractional<=1&spell_targets.shuriken_storm=1&(talent.dark_brew|talent.danse_macabre) (if not Player:BuffUp(S.ShadowDanceBuff) instead of Skip_Rupture as it does not work correctly.)
  if not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture and S.Rupture:IsCastable() then
    if MeleeEnemies10yCount == 1 and Player:BuffUp(S.FinalityRuptureBuff) and (S.DarkBrew:IsAvailable() or S.DanseMacabre:IsAvailable())
      and S.ShadowDance:CooldownRemains() < 12 and S.ShadowDance:ChargesFractional() <= 1 then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture (Finality)" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end

  -- actions.finish+=/cold_blood,if=variable.secret_condition&cooldown.secret_technique.ready
  if S.ColdBlood:IsReady() and Secret_Condition(ShadowDanceBuff, PremeditationBuff) and S.SecretTechnique:CooldownUp() then
    if Settings.Commons.OffGCDasOffGCD.ColdBlood then
      HR.Cast(S.ColdBlood, Settings.Commons.OffGCDasOffGCD.ColdBlood)
    else
      if ReturnSpellOnly then return S.ColdBlood end
      if HR.Cast(S.ColdBlood) then return "Cast Cold Blood (SecTec)" end
    end
  end
  -- actions.finish+=/secret_technique,if=variable.secret_condition&(!talent.cold_blood|cooldown.cold_blood.remains>buff.shadow_dance.remains-2|!talent.improved_shadow_dance)
  -- Attention: Due to the SecTec/ColdBlood interaction, this adaption has additional checks not found in the APL string (check if "or (Player:BuffUp(S.ShurikenTornado) and Player:BuffStack(S.DanseMacabreBuff) >= 2 and MeleeEnemies10yCount >= 3))" is still relevant)
  if S.SecretTechnique:IsReady() and Secret_Condition(ShadowDanceBuff, PremeditationBuff) 
      and (not S.ColdBlood:IsAvailable() or S.ColdBlood:CooldownRemains() > ShadowDanceBuffRemains - 2 or not S.ImprovedShadowDance:IsAvailable()) then
      if ReturnSpellOnly then return S.SecretTechnique end
      if HR.Cast(S.SecretTechnique) then return "Cast Secret Technique" end
  end

  if not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture and S.Rupture:IsCastable() then
    -- actions.finish+=/rupture,cycle_targets=1,if=!variable.skip_rupture&!variable.priority_rotation&spell_targets.shuriken_storm>=2&target.time_to_die>=(2*combo_points)&refreshable (if not Player:BuffUp(S.ShadowDanceBuff) instead of Skip_Rupture as it does not work correctly.)
    if not ReturnSpellOnly and HR.AoEON() and not PriorityRotation and MeleeEnemies10yCount >= 2 then
      local function Evaluate_Rupture_Target(TargetUnit)
        return Everyone.CanDoTUnit(TargetUnit, RuptureDMGThreshold)
          and TargetUnit:DebuffRefreshable(S.Rupture, RuptureThreshold)
      end
      SuggestCycleDoT(S.Rupture, Evaluate_Rupture_Target, (2 * FinishComboPoints), MeleeEnemies5y)
    end
    -- actions.finish+=/rupture,if=!variable.skip_rupture&remains<cooldown.symbols_of_death.remains+10&cooldown.symbols_of_death.remains<=5&target.time_to_die-remains>cooldown.symbols_of_death.remains+5 (if not Player:BuffUp(S.ShadowDanceBuff) instead of Skip_Rupture as it does not work correctly.)
    if TargetInMeleeRange and Target:DebuffRemains(S.Rupture) < S.SymbolsofDeath:CooldownRemains() + 10
      and S.SymbolsofDeath:CooldownRemains() <= 5
      and Rogue.CanDoTUnit(Target, RuptureDMGThreshold)
      and Target:FilteredTimeToDie(">", 5 + S.SymbolsofDeath:CooldownRemains(), -Target:DebuffRemains(S.Rupture)) then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture 2" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&spell_targets>=3|!used_for_danse&buff.shadow_dance.up&spell_targets.shuriken_storm=2&talent.danse_macabre
  if S.BlackPowder:IsCastable() and (not PriorityRotation and MeleeEnemies10yCount >= 3
    or (MeleeEnemies10yCount == 2 and ShadowDanceBuff and S.DanseMacabre:IsAvailable() and not Used_For_Danse(S.BlackPowder))) then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsReady() and HR.Cast(S.BlackPowder) then return "Cast Black Powder" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end

  -- actions.finish+=/eviscerate
  if S.Eviscerate:IsCastable() and TargetInMeleeRange then
    if ReturnSpellOnly then
      return S.Eviscerate
    else
      if S.Eviscerate:IsReady() and HR.Cast(S.Eviscerate) then return "Cast Eviscerate" end
      SetPoolingFinisher(S.Eviscerate)
    end
  end

  return false
end

-- # Stealthed Rotation
-- ReturnSpellOnly and StealthSpell parameters are to Predict Finisher in case of Stealth Macros
local function Stealthed (ReturnSpellOnly, StealthSpell)
  local ShadowDanceBuff = Player:BuffUp(S.ShadowDanceBuff)
  local ShadowDanceBuffRemains = Player:BuffRemains(S.ShadowDanceBuff)
  local TheRottenBuff = Player:BuffUp(S.TheRottenBuff)
  local StealthComboPoints, StealthComboPointsDeficit = ComboPoints, ComboPointsDeficit
  
  -- State changes based on predicted Stealth casts
  local PremeditationBuff = Player:BuffUp(S.PremeditationBuff) or (StealthSpell and S.Premeditation:IsAvailable())
  local SilentStormBuff = Player:BuffUp(S.SilentStormBuff) or (StealthSpell and S.SilentStorm:IsAvailable())
  local StealthBuff = Player:BuffUp(Rogue.StealthSpell()) or (StealthSpell and StealthSpell:ID() == Rogue.StealthSpell():ID())
  local VanishBuffCheck = Player:BuffUp(Rogue.VanishBuffSpell()) or (StealthSpell and StealthSpell:ID() == S.Vanish:ID())
  if StealthSpell and StealthSpell:ID() == S.ShadowDance:ID() then
    ShadowDanceBuff = true
    ShadowDanceBuffRemains = 8 + S.ImprovedShadowDance:TalentRank()
    if S.TheRotten:IsAvailable() and Player:HasTier(30, 2) then
      TheRottenBuff = true
    end
    if S.TheFirstDance:IsAvailable() then
      StealthComboPoints = mathmin(Player:ComboPointsMax(), ComboPoints + 4)
      StealthComboPointsDeficit = Player:ComboPointsMax() - StealthComboPoints
    end
  end

  local StealthEffectiveComboPoints = Rogue.EffectiveComboPoints(StealthComboPoints)
  local ShadowstrikeIsCastable = S.Shadowstrike:IsCastable() or StealthBuff or VanishBuffCheck or ShadowDanceBuff or Player:BuffUp(S.SepsisBuff)
  if StealthBuff or VanishBuffCheck then
    ShadowstrikeIsCastable = ShadowstrikeIsCastable and Target:IsInRange(25)
  else
    ShadowstrikeIsCastable = ShadowstrikeIsCastable and TargetInMeleeRange
  end

  -- actions.stealthed=shadowstrike,if=(buff.stealth.up)&(spell_targets.shuriken_storm<4|variable.priority_rotation)
  if ShadowstrikeIsCastable and StealthBuff and (MeleeEnemies10yCount < 4 or PriorityRotation) then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike (Stealth)" end
    end
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=variable.effective_combo_points>=cp_max_spend
  if StealthEffectiveComboPoints >= Rogue.CPMaxSpend() then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=buff.shuriken_tornado.up&combo_points.deficit<=2
  if Player:BuffUp(S.ShurikenTornado) and StealthComboPointsDeficit <= 2 then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=spell_targets.shuriken_storm>=4
  if MeleeEnemies10yCount >= 4 then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=combo_points.deficit<=1+(talent.deeper_stratagem|talent.secret_stratagem)
  if StealthComboPointsDeficit <= 1 + num(S.DeeperStratagem:IsAvailable() or S.SecretStratagem:IsAvailable()) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end

  -- actions.stealthed+=/backstab,if=buff.shadow_dance.remains>=3&buff.shadow_blades.up&!used_for_danse&talent.danse_macabre&spell_targets.shuriken_storm<=3&!buff.the_rotten.up
  if S.Backstab:IsCastable() then
    if Player:BuffRemains(ShadowDanceBuff) >= 3 and Player:BuffUp(S.ShadowBlades) and not Used_For_Danse(S.Backstab)
        and S.DanseMacabre:IsAvailable() and MeleeEnemies10yCount <= 3 and not Player:BuffUp(S.TheRottenBuff) then
            if ReturnSpellOnly then
                -- If calling from a Stealth macro, we don't need the PV suggestion since it's already a macro cast
                if StealthSpell then
                    return S.Backstab
                    else
                    return { S.Backstab, S.Stealth }
                end
            else
                if HR.CastQueue(S.Backstab, S.Stealth) then return "Cast Backstab (Stealth)" end
            end
        end
    end
  end
  -- actions.stealthed+=/gloomblade,if=buff.shadow_dance.remains>=3&buff.shadow_blades.up&!used_for_danse&talent.danse_macabre&spell_targets.shuriken_storm<=4
  if S.Gloomblade:IsCastable() then
    if Player:BuffRemains(ShadowDanceBuff) >= 3 and Player:BuffUp(S.ShadowBlades) and not Used_For_Danse(S.Gloomblade)
        and S.DanseMacabre:IsAvailable() and MeleeEnemies10yCount <= 4 then
        if ReturnSpellOnly then
            -- If calling from a Stealth macro, we don't need the PV suggestion since it's already a macro cast
            if StealthSpell then
                return S.Gloomblade
                else
                return { S.Gloomblade, S.Stealth }
            end
        else
            if HR.CastQueue(S.Gloomblade, S.Stealth) then return "Cast Gloomblade (Stealth)" end
        end
    end
  end
  -- actions.stealthed+=/shadowstrike,if=stealthed.sepsis&spell_targets.shuriken_storm<4|!used_for_danse&buff.shadow_blades.up
  if ShadowstrikeIsCastable and not Player:StealthUp(true, false) and not StealthSpell and (Player:BuffUp(S.SepsisBuff) and MeleeEnemies10yCount < 4 
    or not Used_For_Danse(S.Shadowstrike) and Player:BuffUp(S.ShadowBlades)) then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike (Sepsis)" end
    end
  end
  -- actions.stealthed+=/shuriken_storm,if=!buff.premeditation.up&spell_targets>=4-(!used_for_danse&talent.danse_macabre)
  if HR.AoEON() and S.ShurikenStorm:IsCastable()
      and not PremeditationBuff
      and MeleeEnemies10yCount >= (4 - BoolToInt(not Used_For_Danse(S.ShurikenStorm) and S.DanseMacabre:IsAvailable())) then
      if ReturnSpellOnly then
          return S.ShurikenStorm
      else
          if HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
      end
  end
  -- actions.stealthed+=/shadowstrike
  if ShadowstrikeIsCastable then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike 2" end
    end
   end

  return false
end

-- # Stealth Macros
-- This returns a table with the original Stealth spell and the result of the Stealthed action list as if the applicable buff was present
local function StealthMacro (StealthSpell, EnergyThreshold)
  -- Fetch the predicted ability to use after the stealth spell
  local MacroAbility = Stealthed(true, StealthSpell)

  -- Handle StealthMacro GUI options
  -- If false, just suggest them as off-GCD and bail out of the macro functionality
  if StealthSpell:ID() == S.Vanish:ID() and (not Settings.Subtlety.StealthMacro.Vanish or not MacroAbility) then
    if HR.Cast(S.Vanish, Settings.Commons.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
    return false
  elseif StealthSpell:ID() == S.Shadowmeld:ID() and (not Settings.Subtlety.StealthMacro.Shadowmeld or not MacroAbility) then
    if HR.Cast(S.Shadowmeld, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Shadowmeld" end
    return false
  elseif StealthSpell:ID() == S.ShadowDance:ID() and (not Settings.Subtlety.StealthMacro.ShadowDance or not MacroAbility) then
    if HR.Cast(S.ShadowDance, Settings.Subtlety.OffGCDasOffGCD.ShadowDance) then return "Cast Shadow Dance" end
    return false
  end

  local MacroTable = {StealthSpell, MacroAbility}

  -- Set the stealth spell only as a pooling fallback if we did not meet the threshold
  if EnergyThreshold and Player:EnergyPredicted() < EnergyThreshold then
    SetPoolingAbility(MacroTable, EnergyThreshold)
    return false
  end

  ShouldReturn = HR.CastQueue(unpack(MacroTable))
  if ShouldReturn then return "| " .. MacroTable[2]:Name() end

  return false
end

-- # Cooldowns
local function CDs ()
  if Player:BuffUp(S.ShurikenTornado) then
  -- actions.cds+=/shadow_dance,use_off_gcd=1,if=!buff.shadow_dance.up&buff.shuriken_tornado.up&buff.shuriken_tornado.remains<=3.5
  -- actions.cds+=/symbols_of_death,use_off_gcd=1,if=buff.shuriken_tornado.up&buff.shuriken_tornado.remains<=3.5&!set_bonus.tier30_2pc
    if S.SymbolsofDeath:IsCastable() and S.ShadowDance:IsCastable() and not Player:BuffUp(S.SymbolsofDeath) and not Player:BuffUp(S.ShadowDanceBuff) then
      if HR.CastQueue(S.ShadowDance, S.BlackPowder) then return "Cast Shadow Dance (during Tornado 1)" end
    elseif S.SymbolsofDeath:IsCastable() and not Player:BuffUp(S.SymbolsofDeath) and not Player:HasTier(30, 2) then
      if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath) then return "Cast Symbols of Death (during Tornado)" end
    elseif S.ShadowDance:IsCastable() and not Player:BuffUp(S.ShadowDanceBuff) then
      if HR.Cast(S.ShadowDance) then return "Cast Shadow Dance (during Tornado 2)" end
    end
  end

  local SnDCondition = SnD_Condition()

  -- actions.cds+=/cold_blood,if=!talent.secret_technique&combo_points>=5
  if S.ColdBlood:IsReady() and not S.SecretTechnique:IsAvailable() and ComboPoints >= 5 then
    if HR.Cast(S.ColdBlood, Settings.Commons.OffGCDasOffGCD.ColdBlood) then return "Cast Cold Blood" end
  end

  if TargetInMeleeRange then
    -- actions.cds+=/sepsis,if=variable.snd_condition&target.time_to_die>=16&(buff.perforated_veins.up|!talent.perforated_veins)
    if S.Sepsis:IsReady() and SnD_Condition() and Target:FilteredTimeToDie(">", 16) then
     if Player:BuffUp(S.PerforatedVeinsBuff) or not S.PerforatedVeins:IsAvailable() then
      if HR.Cast(S.Sepsis) then return "Cast Sepsis" end
     end
    end
    -- actions.cds+=/flagellation,target_if=max:target.time_to_die,if=variable.snd_condition&combo_points>=5&target.time_to_die>10&((!equipped.ashes_of_the_embersoul|trinket.ashes_of_the_embersoul.cooldown.remains<=8)&cooldown.shadow_blades.remains<=3|fight_remains<=28|cooldown.shadow_blades.remains>=14&talent.invigorating_shadowdust&talent.shadow_dance)
    if HR.CDsON() and S.Flagellation:IsReady() and SnDCondition and not Player:StealthUp(false, false) and ComboPoints >= 5 and Target:FilteredTimeToDie(">", 10) and not Player:BuffUp(S.ShadowDanceBuff) then
      if (Trinket_Conditions() and S.ShadowBlades:CooldownRemains() <= 3) 
        or Target:FilteredTimeToDie() <= 28 
        or (S.ShadowBlades:CooldownRemains() >= 14 and S.InvigoratingShadowdust:IsAvailable() and S.ShadowDanceTalent:IsAvailable()) then
        if HR.Cast(S.Flagellation, nil, Settings.Commons.CovenantDisplayStyle) then return "Cast Flagellation" end
      end
    end
  end -- TODO: implement the trinkets
    -- actions.cds+=/pool_resource,for_next=1,if=talent.shuriken_tornado.enabled&!talent.shadow_focus.enabled
    if Player:Energy() >= 60 then
      if HR.Cast(S.ShurikenTornado, Settings.Subtlety.GCDasOffGCD.ShurikenTornado) then return "Cast Shuriken Tornado" end
    elseif not S.ShadowFocus:IsAvailable() then
      if HR.CastPooling(S.ShurikenTornado) then return "Pool for Shuriken Tornado" end
    end
  end
    -- actions.cds+=/symbols_of_death,if=variable.snd_condition&(!buff.the_rotten.up|!set_bonus.tier30_2pc)&buff.symbols_of_death.remains<=3&(!talent.flagellation|cooldown.flagellation.remains>10|buff.shadow_dance.remains>=2&talent.invigorating_shadowdust|cooldown.flagellation.up&combo_points>=5&!talent.invigorating_shadowdust)
    -- TODO: Get this to work
    if S.SymbolsofDeath:IsCastable() then
      if (SnDCondition and (not Player:BuffUp(S.TheRottenBuff) or not Player:HasTier(30, 2)) and 
        Player:BuffRemains(S.SymbolsofDeath) <= 3 and 
        (not S.Flagellation:IsAvailable() or S.Flagellation:CooldownRemains() > 10 or 
        (Player:BuffRemains(ShadowDanceBuff) >= 2 and S.InvigoratingShadowdust:IsAvailable()) or 
        (S.Flagellation:CooldownUp() and ComboPoints >= 5 and not S.InvigoratingShadowdust:IsAvailable()))) then
        if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath) then return "Cast Symbols of Death" end
      end
    end
  end

  if HR.CDsON() then
    -- actions.cds+=/shadow_blades,if=variable.snd_condition&(combo_points<=1|set_bonus.tier31_4pc)&(buff.flagellation_buff.up|buff.flagellation_persist.up|!talent.flagellation)
    if S.ShadowBlades:IsCastable() then
      if SnDCondition and (ComboPoints <= 1 or Player:HasTier(31, 4)) and 
        (Player:BuffUp(S.Flagellation) or Player:BuffUp(S.FlagellationPersistBuff) or not S.Flagellation:IsAvailable()) then
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades) then return "Cast Shadow Blades" end
      end
    end
    -- actions.cds+=/echoing_reprimand,if=variable.snd_condition&combo_points.deficit>=3&(variable.priority_rotation|spell_targets.shuriken_storm<=4|talent.resounding_clarity)&(buff.shadow_dance.up|!talent.danse_macabre)
    if S.EchoingReprimand:IsReady() and TargetInMeleeRange and ComboPointsDeficit >= 3
      and (PriorityRotation or MeleeEnemies10yCount <= 4 or S.ResoundingClarity:IsAvailable())
      and (Player:BuffUp(S.ShadowDanceBuff) or not S.DanseMacabre:IsAvailable()) then
      if HR.Cast(S.EchoingReprimand, nil, Settings.Commons.CovenantDisplayStyle) then return "Cast Echoing Reprimand" end
    end
    -- actions.cds+=/shuriken_tornado,if=variable.snd_condition&buff.symbols_of_death.up&combo_points<=2&!buff.premeditation.up&(!talent.flagellation|cooldown.flagellation.remains>20)
    -- actions.cds+=/shuriken_tornado,if=cooldown.shadow_dance.ready&!stealthed.all&spell_targets.shuriken_storm>=3&!talent.flagellation.enabled
    -- TODO: check if "and not (Player:BuffUp(S.ShadowDanceBuff) and MeleeEnemies10yCount == 2)" is not needed for SoD condition
    if S.ShurikenTornado:IsReady() then
      if SnD_Condition and Player:BuffUp(S.SymbolsofDeath) and ComboPoints <= 2 and 
        not Player:BuffUp(S.PremeditationBuff) and (not S.Flagellation:IsAvailable() or S.Flagellation:CooldownRemains() > 20) then
        if HR.Cast(S.ShurikenTornado, Settings.Subtlety.GCDasOffGCD.ShurikenTornado) then return "Cast Shuriken Tornado (SoD)" end
      end
      if S.ShadowDance:Charges() >= 1 and not Player:StealthUp(true, true) and MeleeEnemies10yCount >= 3 and not S.Flagellation:IsAvailable() then
        if HR.Cast(S.ShurikenTornado, Settings.Subtlety.GCDasOffGCD.ShurikenTornado) then return "Cast Shuriken Tornado (Dance)" end
      end
    end
    -- actions.cds+=/shadow_dance,if=!buff.shadow_dance.up&fight_remains<=8+talent.subterfuge.enabled
    if S.ShadowDance:IsCastable() and MayBurnShadowDance() and not Player:BuffUp(S.ShadowDanceBuff) and HL.BossFilteredFightRemains("<=", 8) then
      ShouldReturn = StealthMacro(S.ShadowDance)
      if ShouldReturn then return "Shadow Dance Macro (Low TTD) " .. ShouldReturn end
    end
    -- actions.cds+=/goremaws_bite,if=variable.snd_condition&combo_points.deficit>=3&(!cooldown.shadow_dance.up|talent.shadow_dance&buff.shadow_dance.up&!talent.invigorating_shadowdust|spell_targets.shuriken_storm<4&!talent.invigorating_shadowdust|talent.the_rotten|raid_event.adds.up)
    if S.GoremawsBite:IsCastable() then
      if SnD_Condition() and ComboPointsDeficit >= 3 and (not S.ShadowDance:CooldownUp() or 
        (S.ShadowDanceTalent:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) and not S.InvigoratingShadowdust:IsAvailable()) or 
        (MeleeEnemies10yCount < 4 and not S.InvigoratingShadowdust:IsAvailable()) or S.TheRotten:IsAvailable()) then
        if HR.Cast(S.GoremawsBite) then return "Cast Goremaw's Bite" end
      end
    end
    -- actions.cds+=/thistle_tea,if=(cooldown.symbols_of_death.remains>=3|buff.symbols_of_death.up)&!buff.thistle_tea.up&(energy.deficit>=(100)&(combo_points.deficit>=2|spell_targets.shuriken_storm>=3)|(cooldown.thistle_tea.charges_fractional>=(2.75-0.15*talent.invigorating_shadowdust.rank&cooldown.vanish.up))&buff.shadow_dance.up&dot.rupture.ticking&spell_targets.shuriken_storm<3)|buff.shadow_dance.remains>=4&!buff.thistle_tea.up&spell_targets.shuriken_storm>=3|!buff.thistle_tea.up&fight_remains<=(6*cooldown.thistle_tea.charges)
    if S.ThistleTea:IsReady() then
       if (S.SymbolsofDeath:CooldownRemains() >= 3 or Player:BuffUp(S.SymbolsofDeath)) 
         and not Player:BuffUp(S.ThistleTea)
         and (Player:EnergyDeficitPredicted() >= 100 and (Player:ComboPointsDeficit() >= 2 or MeleeEnemies10yCount >= 3)
         or (S.ThistleTea:ChargesFractional() >= (2.75 - 0.15 * S.InvigoratingShadowdust:TalentRank()) and S.Vanish:CooldownUp()) 
         and Player:BuffUp(S.ShadowDanceBuff) and Target:DebuffUp(S.Rupture) and MeleeEnemies10yCount < 3)
         or Player:BuffRemains(S.ShadowDanceBuff) >= 4 and not Player:BuffUp(S.ThistleTea) and MeleeEnemies10yCount >= 3
         or not Player:BuffUp(S.ThistleTea) and HL.BossFilteredFightRemains("<=", 6 * S.ThistleTea:Charges()) then
         if HR.Cast(S.ThistleTea, nil, Settings.Commons.TrinketDisplayStyle) then return "Thistle Tea"; end
       end
    end

    -- TODO: Add Potion Suggestion (Check if cor)
    -- actions.cds+=/potion,if=buff.bloodlust.react|fight_remains<30|buff.symbols_of_death.up&(buff.shadow_blades.up|cooldown.shadow_blades.remains<=10)
    -- Racials
    if Player:BuffUp(S.SymbolsofDeath) then
      -- actions.cds+=/blood_fury,if=buff.symbols_of_death.up
      if S.BloodFury:IsCastable() then
        if HR.Cast(S.BloodFury, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Blood Fury" end
      end
      -- actions.cds+=/berserking,if=buff.symbols_of_death.up
      if S.Berserking:IsCastable() then
        if HR.Cast(S.Berserking, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Berserking" end
      end
      -- actions.cds+=/fireblood,if=buff.symbols_of_death.up
      if S.Fireblood:IsCastable() then
        if HR.Cast(S.Fireblood, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Fireblood" end
      end
      -- actions.cds+=/ancestral_call,if=buff.symbols_of_death.up
      if S.AncestralCall:IsCastable() then
        if HR.Cast(S.AncestralCall, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Ancestral Call" end
      end
    end

    -- Trinkets TODO: MirrorOfFracturedTomorrows, ashes_of_the_embersoul, witherbarks_branch, BandolierOfTwistedBlades itemcheck
    if Settings.Commons.UseTrinkets then
      -- actions.cds+=/use_item,name=witherbarks_branch,if=buff.shadow_dance.up&buff.shadow_blades.up|(equipped.bandolier_of_twisted_blades|talent.invigorating_shadowdust)&!stealthed.all
      if I.WitherbarksBranch:IsEquippedAndReady() then
        if (Player:BuffUp(S.ShadowDanceBuff) and Player:BuffUp(S.ShadowBlades))
          or ((I.BandolierOfTwistedBlades:IsEquipped() or S.InvigoratingShadowdust:IsAvailable()) and not Player:StealthUp(true, true)) then
          if HR.Cast(I.WitherbarksBranch, nil, Settings.Commons.TrinketDisplayStyle) then return "Witherbark's Branch"; end
        end
      end
      -- actions.cds+=/use_item,name=ashes_of_the_embersoul,if=buff.shadow_dance.up&(buff.shadow_blades.up|equipped.witherbarks_branch)
      if I.AshesOfTheEmbersoul:IsEquippedAndReady() then
        if Player:BuffUp(S.ShadowDanceBuff) and (Player:BuffUp(S.ShadowBlades) or I.WitherbarksBranch:IsEquipped()) then
          if HR.Cast(I.AshesOfTheEmbersoul, nil, Settings.Commons.TrinketDisplayStyle) then return "Ashes Of the Embersoul"; end
        end
      end
      -- actions.cds+=/use_item,name=mirror_of_fractured_tomorrows,if=buff.shadow_dance.up&(target.time_to_die>=15|equipped.ashes_of_the_embersoul)
      if I.MirrorOfFracturedTomorrows:IsEquippedAndReady() then
        if Player:BuffUp(S.ShadowDanceBuff) and (Target:FilteredTimeToDie() >= 15 or I.AshesOfTheEmbersoul:IsEquipped()) then
          if HR.Cast(I.MirrorOfFracturedTomorrows, nil, Settings.Commons.TrinketDisplayStyle) then return "Mirror Of Fractured Tomorrows"; end
        end
      end
      -- actions.cds+=/use_item,name=manic_grieftorch,use_off_gcd=1,if=!stealthed.all&(!raid_event.adds.up|!equipped.stormeaters_boon|trinket.stormeaters_boon.cooldown.remains>20)
      if I.ManicGrieftorch:IsEquippedAndReady() then
        if (not Player:StealthUp(true, true)
            and (not I.StormEatersBoon:IsEquipped()
                or I.StormEatersBoon:CooldownRemains() > 20)) then
            if HR.Cast(I.ManicGrieftorch, nil, Settings.Commons.TrinketDisplayStyle) then return "Manic Grieftorch" end
        end
      end
      -- actions.cds+=/use_item,name=beacon_to_the_beyond,use_off_gcd=1,if=!stealthed.all&(buff.deeper_daggers.up|!talent.deeper_daggers)&(!raid_event.adds.up|!equipped.stormeaters_boon|trinket.stormeaters_boon.cooldown.remains>20)
      if I.BeaconToTheBeyond:IsEquippedAndReady() then
        if (not Player:StealthUp(true, true)
            and (Player:BuffUp(S.DeeperDaggersBuff)
                or not S.DeeperDaggers:IsAvailable())
            and (not I.StormEatersBoon:IsEquipped()
                or I.StormEatersBoon:CooldownRemains() > 20)) then
            if HR.Cast(I.BeaconToTheBeyond, nil, Settings.Commons.TrinketDisplayStyle) then return "Beacon To The Beyond" end
        end
      end
      -- actions.cds+=/use_items,if=!stealthed.all|fight_remains<10
      if not Player:StealthUp(true, true) or HL.BossFilteredFightRemains("<", 10) then
        local TrinketToUse = Player:GetUseableItems(OnUseExcludes)
        if TrinketToUse then
            if HR.Cast(TrinketToUse, nil, Settings.Commons.TrinketDisplayStyle) then
                return "Generic use_items for " .. TrinketToUse:Name()
            end
        end
      end
    end
  end

  return false
end

-- # Stealth Cooldowns
local function Stealth_CDs (EnergyThreshold)
  if HR.CDsON()
    -- actions.stealth_cds+=/vanish,if=(combo_points.deficit>1|buff.shadow_blades.up&talent.invigorating_shadowdust)&!variable.shd_threshold&(cooldown.flagellation.remains>=60|!talent.flagellation|fight_remains<=(30*cooldown.vanish.charges))&(cooldown.symbols_of_death.remains>3|!set_bonus.tier30_2pc)&(cooldown.secret_technique.remains>=10|!talent.secret_technique|cooldown.vanish.charges>=2&talent.invigorating_shadowdust&(buff.the_rotten.up|!talent.the_rotten)&!raid_event.adds.up)
    -- TODO: Get this to work
      if S.Vanish:IsCastable()
        and (ComboPointsDeficit > 1 or (Player:BuffUp(S.ShadowBlades) and S.InvigoratingShadowdust:IsAvailable()))
        and not ShD_Threshold()
        and (S.Flagellation:CooldownRemains() >= 60 or not S.Flagellation:IsAvailable() or HL.BossFilteredFightRemains("<=", 30 * S.Vanish:Charges()))
        and (S.SymbolsofDeath:CooldownRemains() > 3 or not Player:HasTier(30, 2))
        and (S.SecretTechnique:CooldownRemains() >= 10 or not S.SecretTechnique:IsAvailable() or S.Vanish:Charges() >= 2 and S.InvigoratingShadowdust:IsAvailable() and (Player:BuffUp(S.TheRottenBuff) or not S.TheRotten:IsAvailable())) then
        ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
        if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
      end
    -- actions.stealth_cds+=/shadowmeld,if=energy>=40&energy.deficit>=10&!variable.shd_threshold&combo_points.deficit>4
    if S.Shadowmeld:IsCastable() and TargetInMeleeRange and not Player:IsMoving()
      and Player:EnergyDeficitPredicted() > 10 and not ShD_Threshold() and ComboPointsDeficit > 4 then
      -- actions.stealth_cds+=/pool_resource,for_next=1,extra_amount=40, if=race.night_elf
      if Player:Energy() < 40 then
        if HR.CastPooling(S.Shadowmeld, Player:EnergyTimeToX(40)) then return "Pool for Shadowmeld" end
      end
      ShouldReturn = StealthMacro(S.Shadowmeld, EnergyThreshold)
      if ShouldReturn then return "Shadowmeld Macro " .. ShouldReturn end
    end
  end
  if TargetInMeleeRange and S.ShadowDance:IsCastable() and HR.CDsON() then
    -- actions.stealth_cds+=/shadow_dance,if=variable.rotten&(!talent.the_first_dance|combo_points.deficit>=4|buff.shadow_blades.up)&(variable.shd_combo_points&variable.shd_threshold|(buff.shadow_blades.up|cooldown.symbols_of_death.up&!talent.sepsis|buff.symbols_of_death.remains>=6&!set_bonus.tier30_2pc|!buff.symbols_of_death.remains&set_bonus.tier30_2pc)&cooldown.secret_technique.remains<10+12*(!talent.invigorating_shadowdust|set_bonus.tier30_2pc))
    -- NOTE: |buff.flagellation.up is a dead operation in SimC due to a typo, since the buff we use in-game is buff.flagellation_buff.up, ignoring
    if Rotten_Threshold() and 
        (not S.TheFirstDance:IsAvailable() or ComboPointsDeficit >= 4 or Player:BuffUp(S.ShadowBlades)) and
        (ShD_Combo_Points() and ShD_Threshold() or 
        (Player:BuffUp(S.ShadowBlades) or 
        (S.SymbolsofDeath:CooldownUp() and not S.Sepsis:IsAvailable()) or 
        (Player:BuffRemains(S.SymbolsofDeath) >= 6 and not Player:HasTier(30, 2)) or 
        (not Player:BuffUp(S.SymbolsofDeath) and Player:HasTier(30, 2))) and
        S.SecretTechnique:CooldownRemains() < 10 + 12 * (not S.InvigoratingShadowdust:IsAvailable() or Player:HasTier(30, 2))) then
        ShouldReturn = StealthMacro(S.ShadowDance, EnergyThreshold)
        if ShouldReturn then return "ShadowDance Macro " .. ShouldReturn end
    end
  end
  return false
end

-- # Builders
local function Build (EnergyThreshold)
  local ThresholdMet = not EnergyThreshold or Player:EnergyPredicted() >= EnergyThreshold
  -- actions.build=shuriken_storm,if=spell_targets>=2+(talent.gloomblade&buff.lingering_shadow.remains>=6|buff.perforated_veins.up)
  if HR.AoEON() and S.ShurikenStorm:IsCastable()
    and MeleeEnemies10yCount >= 2 + BoolToInt(S.Gloomblade:IsAvailable() and Player:BuffRemains(S.LingeringShadowBuff) >= 6 or Player:BuffUp(S.PerforatedVeinsBuff)) then
    if ThresholdMet and HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
    SetPoolingAbility(S.ShurikenStorm, EnergyThreshold)
  end
  if TargetInMeleeRange then
    -- # Build immediately unless the next CP is Animacharged and we won't cap energy waiting for it.
    -- actions.build+=/variable,name=anima_helper,value=!talent.echoing_reprimand.enabled|!(variable.is_next_cp_animacharged&(time_to_sht.3.plus<0.5|time_to_sht.4.plus<1)&energy<60)
    if S.EchoingReprimand:IsAvailable() and Player:Energy() < 60
      and (ComboPoints == 2 and Player:BuffUp(S.EchoingReprimand3)
        or ComboPoints == 3 and Player:BuffUp(S.EchoingReprimand4)
        or ComboPoints == 4 and Player:BuffUp(S.EchoingReprimand5))
      and (Rogue.TimeToSht(3) < 0.5 or Rogue.TimeToSht(4) < 1.0 or Rogue.TimeToSht(5) < 1.0) then
      HR.Cast(S.PoolEnergy)
      return "ER Generator Pooling"
    end
    -- actions.build+=/gloomblade,if=variable.anima_helper
    if S.Gloomblade:IsCastable() then
      if ThresholdMet and HR.Cast(S.Gloomblade) then return "Cast Gloomblade" end
      SetPoolingAbility(S.Gloomblade, EnergyThreshold)
    -- actions.build+=/backstab,if=variable.anima_helper
    elseif S.Backstab:IsCastable() then
      if ThresholdMet and HR.Cast(S.Backstab) then return "Cast Backstab" end
      SetPoolingAbility(S.Backstab, EnergyThreshold)
    end
  end
  return false
end

local Interrupts = {
  {S.Blind, "Cast Blind (Interrupt)", function () return true end},
  {S.KidneyShot, "Cast Kidney Shot (Interrupt)", function () return ComboPoints > 0 end},
  {S.CheapShot, "Cast Cheap Shot (Interrupt)", function () return Player:StealthUp(true, true) end}
}

-- APL Main
local function APL ()
  -- Reset pooling cache
  PoolingAbility = nil
  PoolingFinisher = nil
  PoolingEnergy = 0

  -- Unit Update
  MeleeRange = S.AcrobaticStrikes:IsAvailable() and 8 or 5
  AoERange = S.AcrobaticStrikes:IsAvailable() and 13 or 10
  TargetInMeleeRange = Target:IsInMeleeRange(MeleeRange)
  TargetInAoERange = Target:IsInMeleeRange(AoERange)
  if AoEON() then
    Enemies30y = Player:GetEnemiesInRange(30) -- Serrated Bone Spike
    MeleeEnemies10y = Player:GetEnemiesInMeleeRange(AoERange) -- Shuriken Storm & Black Powder
    MeleeEnemies10yCount = #MeleeEnemies10y
    MeleeEnemies5y = Player:GetEnemiesInMeleeRange(MeleeRange) -- Melee cycle
  else
    Enemies30y = {}
    MeleeEnemies10y = {}
    MeleeEnemies10yCount = 1
    MeleeEnemies5y = {}
  end

  -- Cache updates
  ComboPoints = Player:ComboPoints()
  EffectiveComboPoints = Rogue.EffectiveComboPoints(ComboPoints)
  ComboPointsDeficit = Player:ComboPointsDeficit()
  PriorityRotation = UsePriorityRotation()
  StealthEnergyRequired = Player:EnergyMax() - Stealth_Threshold()

  -- Adjust Animacharged CP Prediction for Shadow Techniques
  -- If we are on a non-optimal Animacharged CP, ignore it if the time to ShT is less than GCD + 500ms, unless the ER buff will expire soon
  -- Reduces the risk of queued finishers into ShT procs for non-optimal CP amounts
  -- This is an adaptation of the following APL lines:
  -- actions+=/variable,name=is_next_cp_animacharged,if=talent.echoing_reprimand.enabled,value=combo_points=1&buff.echoing_reprimand_2.up|combo_points=2&buff.echoing_reprimand_3.up|combo_points=3&buff.echoing_reprimand_4.up|combo_points=4&buff.echoing_reprimand_5.up
  -- actions+=/variable,name=effective_combo_points,value=effective_combo_points
  -- actions+=/variable,name=effective_combo_points,if=talent.echoing_reprimand.enabled&effective_combo_points>combo_points&combo_points.deficit>2&time_to_sht.4.plus<0.5&!variable.is_next_cp_animacharged,value=combo_points
  if EffectiveComboPoints > ComboPoints and ComboPointsDeficit > 2 and Player:AffectingCombat() then
    if ComboPoints == 2 and not Player:BuffUp(S.EchoingReprimand3)
    or ComboPoints == 3 and not Player:BuffUp(S.EchoingReprimand4)
    or ComboPoints == 4 and not Player:BuffUp(S.EchoingReprimand5) then
      local TimeToSht = Rogue.TimeToSht(4)
      if TimeToSht == 0 then TimeToSht = Rogue.TimeToSht(5) end
      if TimeToSht < (mathmax(Player:EnergyTimeToX(35), Player:GCDRemains()) + 0.5) then
        EffectiveComboPoints = ComboPoints
      end
    end
  end

  -- Shuriken Tornado Combo Point Prediction
  if Player:BuffUp(S.ShurikenTornado, nil, true) and ComboPoints < Rogue.CPMaxSpend() then
    local TimeToNextTornadoTick = Rogue.TimeToNextTornado()
    if TimeToNextTornadoTick <= Player:GCDRemains() or mathabs(Player:GCDRemains() - TimeToNextTornadoTick) < 0.25 then
      local PredictedComboPointGeneration = MeleeEnemies10yCount + num(Player:BuffUp(S.ShadowBlades))
      ComboPoints = mathmin(ComboPoints + PredictedComboPointGeneration, Rogue.CPMaxSpend())
      ComboPointsDeficit = mathmax(ComboPointsDeficit - PredictedComboPointGeneration, 0)
      if EffectiveComboPoints < Rogue.CPMaxSpend() then
        EffectiveComboPoints = ComboPoints
      end
    end
  end

  -- Damage Cache updates (after EffectiveComboPoints adjustments)
  RuptureThreshold = (4 + EffectiveComboPoints * 4) * 0.3
  RuptureDMGThreshold = S.Eviscerate:Damage()*Settings.Subtlety.EviscerateDMGOffset; -- Used to check if Rupture is worth to be casted since it's a finisher.

  --- Defensives
  -- Crimson Vial
  ShouldReturn = Rogue.CrimsonVial()
  if ShouldReturn then return ShouldReturn end
  -- Feint
  ShouldReturn = Rogue.Feint()
  if ShouldReturn then return ShouldReturn end

  -- Poisons
  Rogue.Poisons()

  --- Out of Combat
  if not Player:AffectingCombat() then
    -- actions=stealth
    -- Note: Since 7.2.5, Blizzard disallowed Stealth cast under ShD (workaround to prevent the Extended Stealth bug)
    if not Player:BuffUp(S.ShadowDanceBuff) and not Player:BuffUp(Rogue.VanishBuffSpell()) then
      ShouldReturn = Rogue.Stealth(Rogue.StealthSpell())
      if ShouldReturn then return ShouldReturn end
    end
    -- actions.precombat+=/symbols_of_death,if=talent.invigorating_shadowdust TODO: Get this to work lol
    if HR.CDsON() then
      if S.SymbolsOfDeath:IsCastable() and S.InvigoratingShadowdust:IsAvailable() then
        if HR.Cast(S.SymbolsOfDeath) then return "Cast Symbols of Death (OOC)" end
      end
    end
    -- Flask
    -- Food
    -- Rune
    -- PrePot w/ Bossmod Countdown
    -- Opener
    if Everyone.TargetIsValid() and (Target:IsSpellInRange(S.Shadowstrike) or TargetInMeleeRange) then
      -- Precombat CDs
      if HR.CDsON() then
        if S.MarkedforDeath:IsCastable() and Player:ComboPointsDeficit() >= Rogue.CPMaxSpend() then
          if HR.Cast(S.MarkedforDeath, Settings.Commons.OffGCDasOffGCD.MarkedforDeath) then return "Cast Marked for Death (OOC)" end
        end
      end
      if Player:StealthUp(true, true) then
        PoolingAbility = Stealthed(true)
        if PoolingAbility then -- To avoid pooling icon spam
          if type(PoolingAbility) == "table" and #PoolingAbility > 1 then
            if HR.CastQueuePooling(nil, unpack(PoolingAbility)) then return "Stealthed Macro Cast or Pool (OOC): ".. PoolingAbility[1]:Name() end
          else
            if HR.CastPooling(PoolingAbility) then return "Stealthed Cast or Pool (OOC): "..PoolingAbility:Name() end
          end
        end
      elseif ComboPoints >= 5 then
        ShouldReturn = Finish()
        if ShouldReturn then return ShouldReturn .. " (OOC)" end
      elseif S.Backstab:IsCastable() then
        if HR.Cast(S.Backstab) then return "Cast Backstab (OOC)" end
      end
    end
    return
  end

  -- In Combat
  -- MfD Sniping
  Rogue.MfDSniping(S.MarkedforDeath)

  if Everyone.TargetIsValid() then
    -- actions+=/kick
    ShouldReturn = Everyone.Interrupt(5, S.Kick, Settings.Commons2.OffGCDasOffGCD.Kick, Interrupts)
    if ShouldReturn then return ShouldReturn end

    -- # Check CDs at first
    -- actions=call_action_list,name=cds
    ShouldReturn = CDs()
    if ShouldReturn then return "CDs: " .. ShouldReturn end

    -- # Apply Slice and Dice at 4+ CP if it expires within the next 3 seconds or is not up (some extra condition for when no tier 30, dunno, will sim in due time)
    -- actions+=/slice_and_dice,if=spell_targets.shuriken_storm<cp_max_spend&fight_remains>6&combo_points>=4&(buff.slice_and_dice.remains<3&set_bonus.tier30_2pc|buff.slice_and_dice.remains<gcd.max&!set_bonus.tier30_2pc)
    if S.SliceandDice:IsCastable() and MeleeEnemies10yCount < Rogue.CPMaxSpend() and HL.FilteredFightRemains(MeleeEnemies10y, ">", 6) and ComboPoints >= 4 then
        if (Player:HasTier(30, 2) and Player:BuffRemains(S.SliceandDice) < 3) or 
            (not Player:HasTier(30, 2) and Player:BuffRemains(S.SliceandDice) < Player:GCD()) then
            if S.SliceandDice:IsReady() and HR.Cast(S.SliceandDice) then return "Cast Slice and Dice (Low Duration)" end
        end
    end

    -- # Run fully switches to the Stealthed Rotation (by doing so, it forces pooling if nothing is available).
    -- actions+=/run_action_list,name=stealthed,if=stealthed.all
    if Player:StealthUp(true, true) then
      PoolingAbility = Stealthed(true)
      if PoolingAbility then -- To avoid pooling icon spam
        if type(PoolingAbility) == "table" and #PoolingAbility > 1 then
          if HR.CastQueuePooling(nil, unpack(PoolingAbility)) then return "Stealthed Macro " .. PoolingAbility[1]:Name() .. "|" .. PoolingAbility[2]:Name() end
        else
          -- Special case for Shuriken Tornado
          if Player:BuffUp(S.ShurikenTornado) and ComboPoints ~= Player:ComboPoints()
            and (PoolingAbility == S.SecretTechnique or PoolingAbility == S.BlackPowder or PoolingAbility == S.Eviscerate or PoolingAbility == S.Rupture) then
            if HR.CastQueuePooling(nil, S.ShurikenTornado, PoolingAbility) then return "Stealthed Tornado Cast  " .. PoolingAbility:Name() end
          else  
            if HR.CastPooling(PoolingAbility) then return "Stealthed Cast " .. PoolingAbility:Name() end
          end
        end
      end
      HR.Cast(S.PoolEnergy)
      return "Stealthed Pooling"
    end

    -- actions+=/call_action_list,name=stealth_cds,if=energy.deficit<=variable.stealth_threshold
    if Player:EnergyPredicted() >= StealthEnergyRequired then
      ShouldReturn = Stealth_CDs()
      if ShouldReturn then return "Stealth CDs: " .. ShouldReturn end
    end

    -- actions+=/call_action_list,name=finish,if=variable.effective_combo_points>=cp_max_spend
    -- # Finish at maximum or close to maximum combo point value
    -- actions+=/call_action_list,name=finish,if=combo_points.deficit<=1|fight_remains<=1&variable.effective_combo_points>=3
    -- # Finish at 4+ against 4 targets (outside stealth)
    -- actions+=/call_action_list,name=finish,if=spell_targets.shuriken_storm>=4&variable.effective_combo_points>=4
    if EffectiveComboPoints >= Rogue.CPMaxSpend()
      or (ComboPointsDeficit <= 1 or (HL.BossFilteredFightRemains("<", 1) and EffectiveComboPoints >= 3))
      or (MeleeEnemies10yCount >= 4 and EffectiveComboPoints >= 4) then
      ShouldReturn = Finish()
      if ShouldReturn then return "Finish: " .. ShouldReturn end
    else
      -- NOTE: Duplicated stealth_cds line from above since both this and build have the same energy threshold if condition
      -- If we aren't finishing in between, we'll be suggesting to pool something and re-process with StealthEnergyRequired

      -- # Consider using a Stealth CD when reaching the energy threshold, called with params to register potential pooling
      -- actions+=/call_action_list,name=stealth_cds,if=energy.deficit<=variable.stealth_threshold
      ShouldReturn = Stealth_CDs(StealthEnergyRequired)
      if ShouldReturn then return "Stealth CDs: " .. ShouldReturn end

      -- # Use a builder when reaching the energy threshold
      -- actions+=/call_action_list,name=build,if=energy.deficit<=variable.stealth_threshold
      ShouldReturn = Build(StealthEnergyRequired)
      if ShouldReturn then return "Build: " .. ShouldReturn end
    end

    if HR.CDsON() then
      -- # Lowest priority in all of the APL because it causes a GCD
      -- actions+=/arcane_torrent,if=energy.deficit>=15+energy.regen
      if S.ArcaneTorrent:IsReady() and TargetInMeleeRange and Player:EnergyDeficitPredicted() > 15 + Player:EnergyRegen() then
        if HR.Cast(S.ArcaneTorrent, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Arcane Torrent" end
      end
      -- actions+=/arcane_pulse
      if S.ArcanePulse:IsReady() and TargetInMeleeRange then
        if HR.Cast(S.ArcanePulse, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Arcane Pulse" end
      end
      -- actions+=/lights_judgment
      if S.LightsJudgment:IsReady() then
        if HR.Cast(S.LightsJudgment, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Lights Judgment" end
      end
      -- actions+=/bag_of_tricks
      if S.BagofTricks:IsReady() then
        if HR.Cast(S.BagofTricks, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Bag of Tricks" end
      end
    end

    -- Show what ever was first stored for pooling
    if PoolingFinisher then SetPoolingAbility(PoolingFinisher) end
    if PoolingAbility and TargetInMeleeRange then
      if type(PoolingAbility) == "table" and #PoolingAbility > 1 then
        if HR.CastQueuePooling(Player:EnergyTimeToX(PoolingEnergy), unpack(PoolingAbility)) then return "Macro pool towards ".. PoolingAbility[1]:Name() .. " at " .. PoolingEnergy end
      elseif PoolingAbility:IsCastable() then
        PoolingEnergy = mathmax(PoolingEnergy, PoolingAbility:Cost())
        if HR.CastPooling(PoolingAbility, Player:EnergyTimeToX(PoolingEnergy)) then return "Pool towards: " .. PoolingAbility:Name() .. " at " .. PoolingEnergy end
      end
    end

    -- Shuriken Toss Out of Range
    if S.ShurikenToss:IsCastable() and Target:IsInRange(30) and not TargetInAoERange and not Player:StealthUp(true, true) and not Player:BuffUp(S.Sprint)
      and Player:EnergyDeficitPredicted() < 20 and (ComboPointsDeficit >= 1 or Player:EnergyTimeToMax() <= 1.2) then
      if HR.CastPooling(S.ShurikenToss) then return "Cast Shuriken Toss" end
    end
  end
end

local function Init ()
  -- Nothing
end

HR.SetAPL(261, APL, Init)

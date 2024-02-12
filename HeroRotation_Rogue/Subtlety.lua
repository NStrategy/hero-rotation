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
local Cast = HR.Cast
local CastLeftNameplate = HR.CastLeftNameplate
local CastPooling = HR.CastPooling
local CastQueue = HR.CastQueue
local CastQueuePooling = HR.CastQueuePooling
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
  I.AshesoftheEmbersoul:ID(),
  I.WitherbarksBranch:ID(),
  I.BattleReadyGoggles:ID(),
  I.PersonalSpaceAmplifier:ID()
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
    -- Heartsbane Triad
    elseif Target:NPCID() == 131823 or Target:NPCID() == 131824 or Target:NPCID() == 131825 then
      return true
    -- Ancient Protectors
    elseif Target:NPCID() == 83894 or Target:NPCID() == 83893 or Target:NPCID() == 83892 then
      return true
    -- Yalnu (Flourishing Ancient)
    elseif Target:NPCID() == 84400 or Target:NPCID() == 83846 then
      return true
    -- Witherbark
    elseif Target:NPCID() == 81522 then
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
  elseif Settings.Commons2.RangedMultiDoT then
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
  -- actions+=/variable,name=stealth_threshold,value=20+talent.vigor.rank*25+talent.thistle_tea*20+talent.shadowcraft*20
  return 20 + S.Vigor:TalentRank() * 25 + num(S.ThistleTea:IsAvailable()) * 20 + num(S.Shadowcraft:IsAvailable()) * 20
end
local function Stealth_Helper ()
  -- actions+=/variable,name=stealth_helper,value=energy>=variable.stealth_threshold
  -- actions+=/variable,name=stealth_helper,value=(energy.deficit-7)<=variable.stealth_threshold,if=talent.dark_brew.enabled&(!talent.vigor.enabled|talent.shadowcraft.enabled)
  -- actions+=/variable,name=stealth_helper,value=energy.deficit<=variable.stealth_threshold,if=talent.invigorating_shadowdust.enabled&(!talent.vigor.enabled|talent.shadowcraft.enabled)
  if S.InvigoratingShadowdust:IsAvailable() and (not S.Vigor:IsAvailable() or S.Shadowcraft:IsAvailable()) then
    return Player:EnergyDeficitPredicted() <= Stealth_Threshold()
  elseif S.DarkBrew:IsAvailable() and (not S.Vigor:IsAvailable() or S.Shadowcraft:IsAvailable()) then
    return (Player:EnergyDeficitPredicted() - 7) <= Stealth_Threshold()
  else
    return Player:Energy() >= Stealth_Threshold()
  end
end
local function ShD_Threshold ()
  -- actions.stealth_cds=variable,name=shd_threshold,value=cooldown.shadow_dance.charges_fractional>=0.75+talent.shadow_dance
  return S.ShadowDance:ChargesFractional() >= 0.75 + BoolToInt(S.ShadowDanceTalent:IsAvailable())
end
local function ShD_Combo_Points ()
  -- actions.stealth_cds+=/variable,name=shd_combo_points,value=combo_points.deficit>=3
  return ComboPointsDeficit >= 3
end
local function SnD_Condition ()
  -- actions+=/variable,name=snd_condition,value=buff.slice_and_dice.up|spell_targets.shuriken_storm>=cp_max_spend
  return Player:BuffUp(S.SliceandDice) or MeleeEnemies10yCount >= Rogue.CPMaxSpend()
end
local function Skip_Rupture (ShadowDanceBuff)
  -- actions.finish+=/variable,name=skip_rupture,value=buff.thistle_tea.up&spell_targets.shuriken_storm=1|buff.shadow_dance.up&(spell_targets.shuriken_storm=1|dot.rupture.ticking&spell_targets.shuriken_storm>=2)
  return Player:BuffUp(S.ThistleTea) and MeleeEnemies10yCount == 1
    or ShadowDanceBuff and (MeleeEnemies10yCount == 1 or Target:DebuffUp(S.Rupture) and MeleeEnemies10yCount >= 2)
end
local function Skip_Rupture_NPC () -- Homebrew exclude for certain NPCs
   -- Rise
  return Target:NPCID() == 206351 or Target:NPCID() == 206352 or Target:NPCID() == 203763 or Target:NPCID() == 203799 or Target:NPCID() == 203857 or Target:NPCID() == 203688 or Target:NPCID() == 205265
   -- Fall 
      or Target:NPCID() == 204536 or Target:NPCID() == 204918
   -- WM
      or Target:NPCID() == 135052 or Target:NPCID() == 134024 or Target:NPCID() == 136330 or Target:NPCID() == 133361 or Target:NPCID() == 131669
   -- BRH
      or Target:NPCID() == 99664 or Target:NPCID() == 98677 or Target:NPCID() == 102781 or Target:NPCID() == 102781
   -- AD
      or Target:NPCID() == 128435 or Target:NPCID() == 127315 or Target:NPCID() == 259205 or Target:NPCID() == 125828
   -- EB
      or Target:NPCID() == 81638
   -- DHT
      or Target:NPCID() == 109908 or Target:NPCID() == 107288 or Target:NPCID() == 100529 or Target:NPCID() == 101074
   -- ToT
      or Target:NPCID() == 429037 or Target:NPCID() == 39960 or Target:NPCID() == 213607 or Target:NPCID() == 213219 or Target:NPCID() == 40923
   -- Affixes
      or Target:NPCID() == 204560 or Target:NPCID() == 174773
   -- Raid
      or Target:NPCID() == 210231 or Target:NPCID() == 207341 or Target:NPCID() == 208459 or Target:NPCID() == 208461 or Target:NPCID() == 214441 or Target:NPCID() == 211306 or Target:NPCID() == 214608
end
-- Maybe do an exlude cd function for Blades and Flag on certain npcs, like for the first adds in Manor. Dunno if that would brick rotation
local function Rotten_CB ()
  -- actions.stealth_cds+=/variable,name=rotten_cb,value=(!buff.the_rotten.up|!set_bonus.tier30_2pc)&(!talent.cold_blood|cooldown.cold_blood.remains<4|cooldown.cold_blood.remains>10)
  return (not Player:BuffUp(S.TheRottenBuff) or not Player:HasTier(30, 2)) and (not S.ColdBlood:IsAvailable() or S.ColdBlood:CooldownRemains() < 4 or S.ColdBlood:CooldownRemains() > 10)
end
local function Used_For_Danse(Spell)
  return Player:BuffUp(S.ShadowDanceBuff) and Spell:TimeSinceLastCast() < S.ShadowDance:TimeSinceLastCast()
end
local function Secret_Condition()
  -- Original conditions for using a finisher (Eviscerate, Black Powder, Rupture) and a builder (Gloomblade, Shadowstrike, Backstab, Shuriken Storm)
  local condition = (Used_For_Danse(S.Gloomblade) or Used_For_Danse(S.Shadowstrike) or Used_For_Danse(S.Backstab) or Used_For_Danse(S.ShurikenStorm)) 
                    and (Used_For_Danse(S.Eviscerate) or Used_For_Danse(S.BlackPowder) or Used_For_Danse(S.Rupture)) 
                    or not S.DanseMacabre:IsAvailable()
  -- Check if Shadowblades is active and Backstab conditions are met
  if Player:BuffUp(S.ShadowBlades) and Player:BuffRemains(S.ShadowBlades) >= 7 and not PremeditationBuff and Player:BuffRemains(S.ShadowDanceBuff) >= 3 
     and S.DanseMacabre:IsAvailable() and MeleeEnemies10yCount <= 3 and not Used_For_Danse(S.Backstab) then
     -- Require Backstab to be used for the condition to be true
     condition = condition and Used_For_Danse(S.Backstab)
  end

  return condition
end
local function Trinket_Conditions () -- Fuus APL
  -- actions.cds=variable,name=trinket_conditions,value=(!equipped.witherbarks_branch|equipped.witherbarks_branch&trinket.witherbarks_branch.cooldown.remains<=8|equipped.bandolier_of_twisted_blades|talent.invigorating_shadowdust)
  return (not I.WitherbarksBranch:IsEquippedAndReady() or 
         I.WitherbarksBranch:IsEquippedAndReady() and I.WitherbarksBranch:CooldownRemains() <= 8 or 
         I.BandolierOfTwistedBlades:IsEquippedAndReady() or S.InvigoratingShadowdust:IsAvailable())
end
local function DefensiveVanish ()
	-- function to excluding vanish in rotation if using Cloaked in Shadows, idea is to have at least 1 charge of Vanish for mechanics/1 Vanish charge always lining up with Blades and Flag
  if S.CloakedinShadows:IsAvailable() then
    return true
  else
    return false
  end
end


-- # Finishers
-- ReturnSpellOnly and StealthSpell parameters are to Predict Finisher in case of Stealth Macros
local function Finish (ReturnSpellOnly, StealthSpell)
  local ShadowDanceBuff = Player:BuffUp(S.ShadowDanceBuff)
  local ShadowDanceBuffRemains = Player:BuffRemains(S.ShadowDanceBuff)
  local SymbolsofDeathBuffRemains = Player:BuffRemains(S.SymbolsofDeath)
  local FinishComboPoints = ComboPoints
  local ColdBloodCDRemains = S.ColdBlood:CooldownRemains()
  local SymbolsCDRemains = S.SymbolsofDeath:CooldownRemains()

  -- State changes based on predicted Stealth casts
  local PremeditationBuff = Player:BuffUp(S.PremeditationBuff) or (StealthSpell and S.Premeditation:IsAvailable())
  if StealthSpell and StealthSpell:ID() == S.ShadowDance:ID() then
    ShadowDanceBuff = true
    ShadowDanceBuffRemains = 6 + (S.ImprovedShadowDance:IsAvailable() and 2 or 0)
    if S.TheFirstDance:IsAvailable() then
      FinishComboPoints = mathmin(Player:ComboPointsMax(), ComboPoints + 4)
    end
    if Player:HasTier(30, 2) then
      SymbolsofDeathBuffRemains = mathmax(SymbolsofDeathBuffRemains, 6)
    end
  end

  local SkipRupture = Skip_Rupture(ShadowDanceBuff)
  -- actions.finish+=/rupture,if=!dot.rupture.ticking&target.time_to_die-remains>6 NOTE: Homebrew check for M+, if at 1 or 2 targets, use Rupture unless the NPC is excluded. If at 3 or more targets, ignore Rupture when in Dance unless priority target, given that at 3 targets you use BlackPowder/AOE.
  if S.Rupture:IsCastable() then
      if not Target:DebuffUp(S.Rupture) and Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) then
          if (MeleeEnemies10yCount <= 2 and (not Skip_Rupture_NPC() or PriorityRotation)) or (MeleeEnemies10yCount >= 3 and (not Skip_Rupture_NPC() or PriorityRotation) and (not Player:BuffUp(S.ShadowDanceBuff) or PriorityRotation)) then
              if ReturnSpellOnly then
                  return S.Rupture
              else
                  if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture 3" end
                  SetPoolingFinisher(S.Rupture)
              end
          end
      end
  end

  -- actions.finish+=/rupture,if=(!variable.skip_rupture|variable.priority_rotation)&target.time_to_die-remains>6&refreshable
  if ((not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture and not Skip_Rupture_NPC()) or PriorityRotation) and S.Rupture:IsCastable() then
    if TargetInMeleeRange
      and (Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid())
      and Rogue.CanDoTUnit(Target, RuptureDMGThreshold)
      and Target:DebuffRefreshable(S.Rupture, RuptureThreshold) then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture 1" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- actions.finish+=/rupture,if=buff.finality_rupture.up&buff.shadow_dance.up&spell_targets.shuriken_storm<=4&!action.rupture.used_for_danse
  if Player:BuffUp(S.FinalityRuptureBuff) and ShadowDanceBuff and not Skip_Rupture_NPC() and MeleeEnemies10yCount <= 4 and not Used_For_Danse(S.Rupture) and S.Rupture:IsCastable() then
    if TargetInMeleeRange then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture (Finality)" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end

  -- actions.finish+=/cold_blood,if=variable.secret_condition&cooldown.secret_technique.ready
  if S.ColdBlood:IsCastable() and Secret_Condition() and S.SecretTechnique:IsCastable() then
    if Settings.Commons.OffGCDasOffGCD.ColdBlood then
      HR.Cast(S.ColdBlood, Settings.Commons.OffGCDasOffGCD.ColdBlood)
    else
      if ReturnSpellOnly then return S.ColdBlood end
      if HR.Cast(S.ColdBlood) then return "Cast Cold Blood (SecTec)" end
    end
  end
  -- actions.finish+=/secret_technique,if=variable.secret_condition&(!talent.cold_blood|cooldown.cold_blood.remains>buff.shadow_dance.remains-2|!talent.improved_shadow_dance)
  -- Attention: Due to the SecTec/ColdBlood interaction, this adaption has additional checks not found in the APL string 
  if S.SecretTechnique:IsCastable() and Secret_Condition()
      and (not S.ColdBlood:IsAvailable() or (Settings.Commons.OffGCDasOffGCD.ColdBlood and S.ColdBlood:IsCastable())
      or Player:BuffUp(S.ColdBlood) or S.ColdBlood:CooldownRemains() > ShadowDanceBuffRemains - 2 or not S.ImprovedShadowDance:IsAvailable()) then
      if ReturnSpellOnly then return S.SecretTechnique end
      if HR.Cast(S.SecretTechnique) then return "Cast Secret Technique" end
  end

  if not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture and not Skip_Rupture_NPC() and S.Rupture:IsCastable() then
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
        if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture 2" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&spell_targets>=3
  if S.BlackPowder:IsCastable() and not PriorityRotation and MeleeEnemies10yCount >= 3 then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsCastable() and HR.Cast(S.BlackPowder) then return "Cast Black Powder" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end

  -- actions.finish+=/eviscerate
  if S.Eviscerate:IsCastable() and TargetInMeleeRange then
    if ReturnSpellOnly then
      return S.Eviscerate
    else
      if S.Eviscerate:IsCastable() and HR.Cast(S.Eviscerate) then return "Cast Eviscerate" end
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
    ShadowDanceBuffRemains = 6 + (S.ImprovedShadowDance:IsAvailable() and 2 or 0)
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

  -- actions.stealthed=shadowstrike,if=buff.stealth.up&(spell_targets.shuriken_storm<4|variable.priority_rotation)
  if ShadowstrikeIsCastable and StealthBuff and MeleeEnemies10yCount < 4 then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike (Stealth)" end
    end
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=effective_combo_points>=cp_max_spend
  if StealthEffectiveComboPoints >= Rogue.CPMaxSpend() then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=buff.shuriken_tornado.up&combo_points.deficit<=2
  if Player:BuffUp(S.ShurikenTornado) and StealthComboPointsDeficit <= 2 then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=combo_points.deficit<=1+(talent.deeper_stratagem|talent.secret_stratagem)
  if StealthComboPointsDeficit <= 1 + num(S.DeeperStratagem:IsAvailable() or S.SecretStratagem:IsAvailable()) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end

  -- actions.stealthed+=/backstab,if=!buff.premeditation.up&buff.shadow_dance.remains>=3&buff.shadow_blades.up&!used_for_danse&talent.danse_macabre&spell_targets.shuriken_storm<=3&!buff.the_rotten.up
  if S.Backstab:IsCastable() then
    if not PremeditationBuff and Player:BuffRemains(S.ShadowDanceBuff) >= 3 and Player:BuffUp(S.ShadowBlades) and not Used_For_Danse(S.Backstab) 
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
  -- actions.stealthed+=/gloomblade,if=!buff.premeditation.up&buff.shadow_dance.remains>=3&buff.shadow_blades.up&!used_for_danse&talent.danse_macabre&spell_targets.shuriken_storm<=4
  if S.Gloomblade:IsCastable() then
    if not PremeditationBuff and Player:BuffRemains(S.ShadowDanceBuff) >= 3 and Player:BuffUp(S.ShadowBlades) and not Used_For_Danse(S.Gloomblade)
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
  -- actions.stealthed+=/shadowstrike,if=!used_for_danse&buff.shadow_blades.up
  if ShadowstrikeIsCastable and not Used_For_Danse(S.Shadowstrike) and Player:BuffUp(S.ShadowBlades) then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadow Strike (Danse)" end
    end
  end
  -- actions.stealthed+=/shuriken_storm,if=!buff.premeditation.up&spell_targets>=4
  if HR.AoEON() and S.ShurikenStorm:IsCastable()
      and not PremeditationBuff
      and MeleeEnemies10yCount >= 4 then
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
    if HR.Cast(S.Vanish, Settings.Subtlety.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
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

  local SnDCondition = SnD_Condition()

  -- actions.cds+=/cold_blood,if=!talent.secret_technique&combo_points>=5
  if S.ColdBlood:IsCastable() and not S.SecretTechnique:IsAvailable() and ComboPoints >= 5 then
    if HR.Cast(S.ColdBlood, Settings.Commons.OffGCDasOffGCD.ColdBlood) then return "Cast Cold Blood" end
  end

  if TargetInMeleeRange then
    -- actions.cds+=/sepsis,if=variable.snd_condition&target.time_to_die>=16&(buff.perforated_veins.up|!talent.perforated_veins) TODO: Settings.Subtlety.OffGCDasOffGCD.Sepsis
    if S.Sepsis:IsCastable() and S.Sepsis:IsAvailable() and SnD_Condition() and Target:FilteredTimeToDie(">", 16) then
     if Player:BuffUp(S.PerforatedVeinsBuff) or not S.PerforatedVeins:IsAvailable() then
      if HR.Cast(S.Sepsis) then return "Cast Sepsis" end
     end
    end
    -- actions.cds+=/flagellation,target_if=max:target.time_to_die,if=variable.snd_condition&combo_points>=5&target.time_to_die>10&(variable.trinket_conditions&cooldown.shadow_blades.remains<=3|fight_remains<=28|cooldown.shadow_blades.remains>=14&talent.invigorating_shadowdust&talent.shadow_dance)&(!talent.invigorating_shadowdust|talent.sepsis|!talent.shadow_dance|talent.invigorating_shadowdust.rank=2&spell_targets.shuriken_storm>=2|cooldown.symbols_of_death.remains<=3|buff.symbols_of_death.remains>3)
    if HR.CDsON() and S.Flagellation:IsAvailable() and S.Flagellation:IsCastable() and SnDCondition and ComboPoints >= 5 and Target:FilteredTimeToDie(">", 10) then
      if (Trinket_Conditions() and S.ShadowBlades:CooldownRemains() <= 3 or HL.BossFilteredFightRemains("<=", 28)
        or S.ShadowBlades:CooldownRemains() >= 14 and S.InvigoratingShadowdust:IsAvailable() and S.ShadowDanceTalent:IsAvailable())
        and (not S.InvigoratingShadowdust:IsAvailable() or S.Sepsis:IsAvailable() or not S.ShadowDanceTalent:IsAvailable()
        or S.InvigoratingShadowdust:TalentRank() == 2 and MeleeEnemies10yCount >= 2 or S.SymbolsofDeath:CooldownRemains() <= 3 or Player:BuffRemains(S.SymbolsofDeath) > 3) then
        if HR.Cast(S.Flagellation, Settings.Subtlety.OffGCDasOffGCD.Flagellation) then return "Cast Flagellation" end
      end
    end
  end 
  -- actions.cds+=/symbols_of_death,if=variable.snd_condition&(!buff.the_rotten.up|!set_bonus.tier30_2pc)&buff.symbols_of_death.remains<=3&(!talent.flagellation|(cooldown.flagellation.remains>10|cooldown.flagellation.remains<2)|buff.shadow_dance.remains>=2&talent.invigorating_shadowdust|cooldown.flagellation.up&combo_points>=5&!talent.invigorating_shadowdust)
  if S.SymbolsofDeath:IsCastable() then
    if (SnDCondition or (not SnDCondition and Player:BuffUp(S.ShadowDanceBuff))) and (not Player:BuffUp(S.TheRottenBuff) or not Player:HasTier(30, 2)) and
      Player:BuffRemains(S.SymbolsofDeath) <= 3 and
      (not S.Flagellation:IsAvailable() or (S.Flagellation:CooldownRemains() > 10 or S.Flagellation:CooldownRemains() < 2) or Player:BuffRemains(S.ShadowDanceBuff) >= 2 and S.InvigoratingShadowdust:IsAvailable() or 
      S.Flagellation:IsCastable() and ComboPoints >= 5 and not S.InvigoratingShadowdust:IsAvailable()) then
      if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath) then return "Cast Symbols of Death" end
    end
  end

  if HR.CDsON() then
    -- actions.cds+=/shadow_blades,if=variable.snd_condition&(combo_points<=1|set_bonus.tier31_4pc)&(((buff.flagellation_buff.up|buff.flagellation_persist.up)&cooldown.shadow_dance.charges_fractional<2)|!talent.flagellation) NS note: cooldown.shadow_dance.charges_fractional<2 offers negligible damage gains but aligns more closely with the rotation outlined in the FAQ
    if S.ShadowBlades:IsCastable() then
      if SnDCondition and (ComboPoints <= 1 or Player:HasTier(31, 4)) and 
        (((Player:BuffUp(S.Flagellation) or (Player:BuffUp(S.FlagellationPersistBuff) and not (Target:NPCID() == 204931))) and S.ShadowDance:ChargesFractional() < 2) or not S.Flagellation:IsAvailable()) then 
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades) then return "Cast Shadow Blades" end
      end
    end
    -- actions.cds+=/echoing_reprimand,if=variable.snd_condition&combo_points.deficit>=3
    if S.EchoingReprimand:IsCastable() and SnDCondition and TargetInMeleeRange and ComboPointsDeficit >= 3 then
      if HR.Cast(S.EchoingReprimand, Settings.Commons.GCDasOffGCD.EchoingReprimand) then return "Cast Echoing Reprimand" end
    end
    -- actions.cds+=/shuriken_tornado,if=variable.snd_condition&buff.symbols_of_death.up&combo_points<=2&!buff.premeditation.up&(!talent.flagellation|cooldown.flagellation.remains>20)&spell_targets.shuriken_storm>=3
    -- actions.cds+=/shuriken_tornado,if=variable.snd_condition&!buff.shadow_dance.up&!buff.flagellation_buff.up&!buff.flagellation_persist.up&!buff.shadow_blades.up&spell_targets.shuriken_storm<=2&!raid_event.adds.up
    if S.ShurikenTornado:IsReady() then
      if SnDCondition and Player:BuffUp(S.SymbolsofDeath) and ComboPoints <= 2 and 
        not PremeditationBuff and (not S.Flagellation:IsAvailable() or S.Flagellation:CooldownRemains() > 20) and MeleeEnemies10yCount >= 3 then
        if HR.Cast(S.ShurikenTornado, Settings.Subtlety.GCDasOffGCD.ShurikenTornado) then return "Cast Shuriken Tornado (SoD)" end
      end
      if SnDCondition and not Player:BuffUp(S.ShadowDanceBuff) and not Player:BuffUp(S.Flagellation) and not Player:BuffUp(S.FlagellationPersistBuff) and not Player:BuffUp(S.ShadowBlades) and MeleeEnemies10yCount <= 2 then
        if HR.Cast(S.ShurikenTornado, Settings.Subtlety.GCDasOffGCD.ShurikenTornado) then return "Cast Shuriken Tornado (ST)" end
      end
    end
    -- actions.cds+=/shadow_dance,if=!buff.shadow_dance.up&fight_remains<=8+talent.subterfuge.enabled
    if S.ShadowDance:IsCastable() and MayBurnShadowDance() and not Player:BuffUp(S.ShadowDanceBuff) and HL.BossFilteredFightRemains("<=", 8) then
      ShouldReturn = StealthMacro(S.ShadowDance)
      if ShouldReturn then return "Shadow Dance Macro (Low TTD) " .. ShouldReturn end
    end
    -- actions.cds+=/goremaws_bite,if=variable.snd_condition&combo_points.deficit>=3&(!cooldown.shadow_dance.up|talent.shadow_dance&buff.shadow_dance.up&!talent.invigorating_shadowdust|spell_targets.shuriken_storm<4&!talent.invigorating_shadowdust|talent.the_rotten|raid_event.adds.up)
    if S.GoremawsBite:IsCastable() then
      if SnDCondition and ComboPointsDeficit >= 3 and (not S.ShadowDance:CooldownUp() or 
        (S.ShadowDanceTalent:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) and not S.InvigoratingShadowdust:IsAvailable()) or 
        (MeleeEnemies10yCount < 4 and not S.InvigoratingShadowdust:IsAvailable()) or S.TheRotten:IsAvailable()) then
        if HR.Cast(S.GoremawsBite) then return "Cast GoremawsBite" end
      end
    end
    -- custom Smolderon condition
    if S.Vanish:IsCastable() then
      if Player:BuffUp(S.ShadowDanceBuff) and S.SecretTechnique:TimeSinceLastCast() < 5 and (Player:BuffUp(S.Flagellation) or Player:BuffUp(S.FlagellationPersistBuff)) and S.ShadowBlades:CooldownRemains() <=32 and Target:NPCID() == 200927 then
        ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
        if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
      end
    end
    -- custom TSwift conditions
    if S.Vanish:IsCastable() then
      if Player:BuffUp(S.ShadowDanceBuff) and S.SecretTechnique:TimeSinceLastCast() < 5 and not (S.Vanish:TimeSinceLastCast() < 5) and Player:BuffUp(S.ShadowBlades) and Target:NPCID() == 209090 then
        ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
        if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
      end
    end
    -- P3 SB Condition
    if S.ShadowBlades:IsCastable() then
      if S.Flagellation:CooldownRemains() <= 27 and S.Flagellation:CooldownRemains() >= 18 and not S.Flagellation:IsCastable() and S.Vanish:IsCastable() and Target:NPCID() == 209090 then
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades) then return "Cast Shadow Blades" end
      end
    end
    -- P2 SB Condition
    if S.ShadowBlades:IsCastable() then
      if S.Flagellation:CooldownRemains() <= 10 and S.Flagellation:CooldownRemains() >= 1 and not S.Flagellation:IsCastable() and Target:NPCID() == 209090 then
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades) then return "Cast Shadow Blades" end
      end
    end
    -- custom Fyrakk Conditions
    if S.Vanish:IsCastable() then
      if Player:BuffUp(S.ShadowDanceBuff) and S.SecretTechnique:TimeSinceLastCast() < 5 and not (S.Vanish:TimeSinceLastCast() < 5) and Player:BuffRemains(S.ShadowBlades) > 12 and (Target:NPCID() == 204931 or Target:NPCID() == 207796 or Target:NPCID() == 214012 or Target:NPCID() == 214608) then
        ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
        if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
      end
    end
    -- Fuu Tea condition
    if S.ThistleTea:IsCastable() then
      -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&cooldown.thistle_tea.charges_fractional>=2.5&buff.shadow_dance.remains>=4 -- Fuus APL
      if not Player:BuffUp(S.ThistleTea) and S.ThistleTea:ChargesFractional() >= 2.5 and Player:BuffRemains(S.ShadowDanceBuff) >= 4 then
        if HR.Cast(S.ThistleTea, Settings.Commons.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea (Max Stacks during Shadow Dance)" end
      end
      -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&buff.shadow_dance.remains>=4&cooldown.secret_technique.remains<=10 -- Fuus APL
      if not Player:BuffUp(S.ThistleTea) and Player:BuffRemains(S.ShadowDanceBuff) >= 4 and S.SecretTechnique:CooldownRemains() <= 10 then
        if HR.Cast(S.ThistleTea, Settings.Commons.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea (Secret Technique ready during Shadow Dance)" end
      end
      -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&(energy.deficit>=(100)|!buff.thistle_tea.up&fight_remains<=(6*cooldown.thistle_tea.charges))&(cooldown.symbols_of_death.remains>=3|buff.symbols_of_death.up)&combo_points.deficit>=2 -- Fuus APL
      if not Player:BuffUp(S.ThistleTea) and (Player:EnergyDeficitPredicted() >= 100 or HL.BossFilteredFightRemains("<=", 6 * S.ThistleTea:Charges())) and 
        (S.SymbolsofDeath:CooldownRemains() >= 3 or Player:BuffUp(S.SymbolsofDeath)) and ComboPointsDeficit >= 2 then
        if HR.Cast(S.ThistleTea, Settings.Commons.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea (Energy Deficit or Fight Duration)" end
      end
    end

    -- actions.cds+=/potion,if=buff.bloodlust.react|fight_remains<30|buff.symbols_of_death.up&(buff.shadow_blades.up|cooldown.shadow_blades.remains<=10)
    if Settings.Commons.Enabled.Potions then
      local PotionSelected = Everyone.PotionSelected()
      if PotionSelected and PotionSelected:IsReady() and (Player:BloodlustUp() or HL.BossFilteredFightRemains("<", 30) or Player:BuffUp(S.SymbolsofDeath)
        and (Player:BuffUp(S.ShadowBlades) or S.ShadowBlades:CooldownRemains() <= 10)) then
        if Cast(PotionSelected, nil, Settings.Commons.DisplayStyle.Potions) then return "Cast Potion"; end
      end
    end
    -- Racials
    -- actions.cds+=/variable,name=racial_sync,value=buff.shadow_blades.up|!talent.shadow_blades&buff.symbols_of_death.up|fight_remains<20
    if Player:BuffUp(S.ShadowBlades) or (not S.ShadowBlades:IsAvailable() and Player:BuffUp(S.SymbolsofDeath)) or HL.BossFilteredFightRemains("<", 20) then
      -- actions.cds+=/blood_fury,if=variable.racial_sync
      if S.BloodFury:IsCastable() then
        if HR.Cast(S.BloodFury, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Blood Fury" end
      end
      -- actions.cds+=/berserking,if=variable.racial_sync
      if S.Berserking:IsCastable() then
        if HR.Cast(S.Berserking, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Berserking" end
      end
      -- actions.cds+=/fireblood,if=variable.racial_sync
      if S.Fireblood:IsCastable() then
        if HR.Cast(S.Fireblood, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Fireblood" end
      end
      -- actions.cds+=/ancestral_call,if=variable.racial_sync
      if S.AncestralCall:IsCastable() then
        if HR.Cast(S.AncestralCall, Settings.Commons.OffGCDasOffGCD.Racials) then return "Cast Ancestral Call" end
      end
    end
    -- Vanish for Defensives
    if (S.Vanish:IsCastable() and DefensiveVanish() and not S.InvigoratingShadowdust:IsAvailable()) and Player:HealthPercentage() <= 30 and not Player:BuffUp(S.CloakedinShadowsBuff) then
      if HR.Cast(S.Vanish, Settings.Subtlety.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
    end
      

    if Settings.Commons.Enabled.Trinkets then
      -- actions.cds+=/use_item,name=ashes_of_the_embersoul,if=(buff.cold_blood.up|(!talent.danse_macabre&buff.shadow_dance.up|buff.danse_macabre.stack>=3)&!talent.cold_blood)|fight_remains<10
      if I.AshesoftheEmbersoul:IsEquippedAndReady() then
        if ((((S.ColdBlood:IsCastable() and ComboPoints >= 5 and S.SecretTechnique:IsCastable() and Secret_Condition()) or Player:BuffUp(S.ColdBlood)) and Player:BuffStack(S.DanseMacabreBuff) >= 3) or (not S.DanseMacabre:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) or Player:BuffStack(S.DanseMacabreBuff) >= 3) and not S.ColdBlood:IsAvailable()) or HL.BossFilteredFightRemains("<", 10) then
           if HR.Cast(I.AshesoftheEmbersoul, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Ashes Of the Embersoul"; end
        end
      end
      -- actions.cds+=/use_item,name=witherbarks_branch,if=buff.flagellation_buff.up&talent.invigorating_shadowdust|buff.shadow_blades.up|equipped.bandolier_of_twisted_blades&raid_event.adds.up
      if I.WitherbarksBranch:IsEquippedAndReady() then
        if (Player:BuffUp(S.Flagellation) and S.InvigoratingShadowdust:IsAvailable()) or
            Player:BuffUp(S.ShadowBlades) or I.BandolierOfTwistedBlades:IsEquipped() then
            if HR.Cast(I.WitherbarksBranch, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Witherbark's Branch"; end
        end
      end
      -- actions.cds+=/use_item,name=mirror_of_fractured_tomorrows,if=buff.shadow_dance.up&(target.time_to_die>=15|equipped.ashes_of_the_embersoul)
      if I.MirrorOfFracturedTomorrows:IsEquippedAndReady() then
        if Player:BuffUp(S.ShadowDanceBuff) and (Target:FilteredTimeToDie(">=", 15) or I.AshesoftheEmbersoul:IsEquipped()) then
          if HR.Cast(I.MirrorOfFracturedTomorrows, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Mirror Of Fractured Tomorrows"; end
        end
      end
      -- actions.cds+=/use_item,name=manic_grieftorch,use_off_gcd=1,if=!stealthed.all&(!raid_event.adds.up|!equipped.stormeaters_boon|trinket.stormeaters_boon.cooldown.remains>20)
      if I.ManicGrieftorch:IsEquippedAndReady() then
        if (not Player:StealthUp(true, true)
            and (not I.StormEatersBoon:IsEquipped()
                or I.StormEatersBoon:CooldownRemains() > 20)) then
            if HR.Cast(I.ManicGrieftorch, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Manic Grieftorch" end
        end
      end
      -- actions.cds+=/use_item,name=beacon_to_the_beyond,use_off_gcd=1,if=!stealthed.all&(buff.deeper_daggers.up|!talent.deeper_daggers)&(!raid_event.adds.up|!equipped.stormeaters_boon|trinket.stormeaters_boon.cooldown.remains>20)
      if I.BeaconToTheBeyond:IsEquippedAndReady() then
        if (not Player:StealthUp(true, true)
            and (Player:BuffUp(S.DeeperDaggersBuff)
                or not S.DeeperDaggers:IsAvailable())
            and (not I.StormEatersBoon:IsEquipped()
                or I.StormEatersBoon:CooldownRemains() > 20)) then
            if HR.Cast(I.BeaconToTheBeyond, nil, Settings.Commons.DisplayStyle.Trinkets) then return "Beacon To The Beyond" end
        end
      end
      -- actions.cds+=/use_items,if=!stealthed.all&(!trinket.mirror_of_fractured_tomorrows.cooldown.ready|!equipped.mirror_of_fractured_tomorrows)&(!trinket.ashes_of_the_embersoul.cooldown.ready|!equipped.ashes_of_the_embersoul)|fight_remains<10
      if not Player:StealthUp(true, true) and (not I.MirrorOfFracturedTomorrows:IsReady() or not I.MirrorOfFracturedTomorrows:IsEquipped()) and (not I.AshesoftheEmbersoul:IsReady() or not I.AshesoftheEmbersoul:IsEquipped())
        or HL.BossFilteredFightRemains("<", 10) then
        local TrinketToUse = Player:GetUseableItems(OnUseExcludes)
        if TrinketToUse then
            if HR.Cast(TrinketToUse, nil, Settings.Commons.DisplayStyle.Trinkets) then
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
  if HR.CDsON() then
    -- actions.stealth_cds+=/vanish,if=(combo_points.deficit>1|buff.shadow_blades.up&talent.invigorating_shadowdust)&!variable.shd_threshold&(cooldown.flagellation.remains>=60|!talent.flagellation|fight_remains<=(30*cooldown.vanish.charges))&(cooldown.symbols_of_death.remains>3|!set_bonus.tier30_2pc)&(cooldown.secret_technique.remains>=10|!talent.secret_technique|cooldown.vanish.charges>=2&talent.invigorating_shadowdust&(buff.the_rotten.up|!talent.the_rotten)&!raid_event.adds.up) -- Maybe do a condition for Smolderon specifically, but probably too difficult
      if (S.Vanish:IsCastable() and ((not DefensiveVanish() or S.Vanish:Charges() >= 2) or S.InvigoratingShadowdust:IsAvailable()))
        and (ComboPointsDeficit > 1 or Player:BuffUp(S.ShadowBlades) and S.InvigoratingShadowdust:IsAvailable()) and not ShD_Threshold()
        and ((S.Flagellation:CooldownRemains() >= 60 and not (Target:NPCID() == 204931 or Target:NPCID() == 207796 or Target:NPCID() == 214012 or Target:NPCID() == 214608)) or not S.Flagellation:IsAvailable() or HL.BossFilteredFightRemains("<=", 30 * S.Vanish:Charges())) and (S.SymbolsofDeath:CooldownRemains() > 3 or not Player:HasTier(30, 2))
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
    -- actions.stealth_cds+=/shadow_dance,if=(dot.rupture.ticking|talent.invigorating_shadowdust)&variable.rotten_cb&(!talent.the_first_dance|combo_points.deficit>=4|buff.shadow_blades.up)&(variable.shd_combo_points&(variable.shd_threshold&(cooldown.symbols_of_death.up|spell_targets>4))|(buff.shadow_blades.up|cooldown.symbols_of_death.up&!talent.sepsis|buff.symbols_of_death.remains>=4&!set_bonus.tier30_2pc|!buff.symbols_of_death.remains&set_bonus.tier30_2pc)&cooldown.secret_technique.remains<10+12*(!talent.invigorating_shadowdust|set_bonus.tier30_2pc))
    -- NOTE: |buff.flagellation.up is a dead operation in SimC due to a typo, since the buff we use in-game is buff.flagellation_buff.up, ignoring
    if  (Target:DebuffUp(S.Rupture) or S.InvigoratingShadowdust:IsAvailable()) and Rotten_CB() and 
        (not S.TheFirstDance:IsAvailable() or ComboPointsDeficit >= 4 or Player:BuffUp(S.ShadowBlades)) and (ShD_Combo_Points() and (ShD_Threshold() and (S.SymbolsofDeath:IsCastable() or (MeleeEnemies10yCount > 4 and not S.ShurikenTornado:IsAvailable() or (MeleeEnemies10yCount > 5 and S.ShurikenTornado:IsAvailable())))) or --nnn
        (Player:BuffUp(S.ShadowBlades) or S.SymbolsofDeath:IsCastable() and not S.Sepsis:IsAvailable() or Player:BuffRemains(S.SymbolsofDeath) >= 4 and not Player:HasTier(30, 2) or 
        not Player:BuffUp(S.SymbolsofDeath) and Player:HasTier(30, 2)) and S.SecretTechnique:CooldownRemains() < 10 + 12 * num(not S.InvigoratingShadowdust:IsAvailable() or Player:HasTier(30, 2))) then
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
    -- actions.build+=/gloomblade
    if S.Gloomblade:IsCastable() then
      if ThresholdMet and HR.Cast(S.Gloomblade) then return "Cast Gloomblade" end
      SetPoolingAbility(S.Gloomblade, EnergyThreshold)
    -- actions.build+=/backstab
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
    Enemies30y = Player:GetEnemiesInRange(30) -- Distract
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
    -- Flask
    -- Food
    -- Rune
    -- PrePot w/ Bossmod Countdown
    -- Opener
    if Everyone.TargetIsValid() and (Target:IsSpellInRange(S.Shadowstrike) or TargetInMeleeRange) then
      -- Precombat CDs
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

  if Everyone.TargetIsValid() then
    -- Interrupts
    ShouldReturn = Everyone.Interrupt(S.Kick, true, Interrupts)
    if ShouldReturn then return ShouldReturn end

    -- Blind
    if S.Blind:IsCastable() and Target:IsInterruptible() and (Target:NPCID() == 204560 or Target:NPCID() == 174773) then
       if S.Blind:IsReady() and HR.Cast(S.Blind, Settings.Commons.GCDasOffGCD.Blind) then return "Blind to CC Affix" end
    end

    -- Maybe do a KidneyShot check for important adds. Archer in Hold for example.
    -- # Check CDs at first
    -- actions=call_action_list,name=cds
    ShouldReturn = CDs()
    if ShouldReturn then return "CDs: " .. ShouldReturn end

    -- actions+=/slice_and_dice,if=spell_targets.shuriken_storm<cp_max_spend&buff.slice_and_dice.remains<gcd.max&fight_remains>6&combo_points>=4 Homebrew: Not in Dance
    if S.SliceandDice:IsCastable() and MeleeEnemies10yCount < Rogue.CPMaxSpend() and HL.FilteredFightRemains(MeleeEnemies10y, ">", 6)
       and Player:BuffRemains(S.SliceandDice) < Player:GCD() and ComboPoints >= 4 and not Player:BuffUp(S.ShadowDanceBuff) then
       if S.SliceandDice:IsCastable() and HR.Cast(S.SliceandDice) then return "Cast Slice and Dice (Low Duration)" end
       SetPoolingFinisher(S.SliceandDice)
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

    -- actions+=/call_action_list,name=stealth_cds,if=variable.stealth_helper|talent.invigorating_shadowdust
    if Stealth_Helper() or S.InvigoratingShadowdust:IsAvailable() then
      ShouldReturn = Stealth_CDs()
      if ShouldReturn then return "Stealth CDs: " .. ShouldReturn end
    end

    -- actions+=/call_action_list,name=finish,if=effective_combo_points>=cp_max_spend
    -- # Finish at maximum or close to maximum combo point value
    -- actions+=/call_action_list,name=finish,if=combo_points.deficit<=1|fight_remains<=1&effective_combo_points>=3
    -- # Finish at 4+ against 4 targets (outside stealth)
    -- actions+=/call_action_list,name=finish,if=spell_targets.shuriken_storm>=4&effective_combo_points>=4
    if EffectiveComboPoints >= Rogue.CPMaxSpend()
      or (ComboPointsDeficit <= 1 or (HL.BossFilteredFightRemains("<=", 1) and EffectiveComboPoints >= 3))
      or (MeleeEnemies10yCount >= 4 and EffectiveComboPoints >= 4) then
      ShouldReturn = Finish()
      if ShouldReturn then return "Finish: " .. ShouldReturn end
    else
      -- # Use a builder when reaching the energy threshold
      -- actions+=/call_action_list,name=build,if=energy.deficit<=variable.stealth_threshold
      ShouldReturn = Build(StealthEnergyRequired)
      if ShouldReturn then return "Build: " .. ShouldReturn end
    end

    if HR.CDsON() then
      -- # Lowest priority in all of the APL because it causes a GCD
      -- actions+=/arcane_torrent,if=energy.deficit>=15+energy.regen
      if S.ArcaneTorrent:IsReady() and TargetInMeleeRange and Player:EnergyDeficitPredicted() >= 15 + Player:EnergyRegen() then
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
  HR.Print("You are using a fork [Version 1.4]: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl")
end

HR.SetAPL(261, APL, Init)

-- Last Update 2023-12-02
-- Using Fuus lasted posted APL in the TC-Subtlety, too lazy to copy :)

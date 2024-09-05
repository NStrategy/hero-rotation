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
local ValueIsInArray = HL.Utils.ValueIsInArray
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
  I.TreacherousTransmitter:ID(),
  I.ImperfectAscendancySerum:ID(),
  I.SkardynsGrace:ID()
}
-- Rotation Var
local MeleeRange, AoERange, TargetInMeleeRange, TargetInAoERange
local Enemies30y, MeleeEnemies10y, MeleeEnemies10yCount, MeleeEnemies5y
local ShouldReturn; -- Used to get the return string
local PoolingAbility, PoolingEnergy, PoolingFinisher; -- Used to store an ability we might want to pool for as a fallback in the current situation
local RuptureThreshold, RuptureDMGThreshold
local EffectiveComboPoints, ComboPoints, ComboPointsDeficit, StealthEnergyRequired
local PriorityRotation
local DungeonSlice
local InRaid

-- Trinkets
local trinket1, trinket2 = Player:GetTrinketItems()
-- If we don't have trinket items, try again in 2 seconds.
if trinket1:ID() == 0 or trinket2:ID() == 0 then
  Delay(2, function()
    trinket1, trinket2 = Player:GetTrinketItems()
  end
  )
end

HL:RegisterForEvent(function()
  trinket1, trinket2 = Player:GetTrinketItems()
end, "PLAYER_EQUIPMENT_CHANGED" )


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
  CommonsDS = HR.GUISettings.APL.Rogue.CommonsDS,
  CommonsOGCD = HR.GUISettings.APL.Rogue.CommonsOGCD,
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
  if Settings.Subtlety.BurnShadowDance == "On Bosses not in Dungeons" and (Player:IsInDungeonArea() or Player:IsInRaid()) then
    return false
  elseif Settings.Subtlety.BurnShadowDance ~= "Always" then -- with that, its actually "never"
    return false
  else
    return true
  end
end

local function UsePriorityRotation()
  if MeleeEnemies10yCount < 2 then
    return false
  elseif Settings.Subtlety.UsePriorityRotation == "Always" then
    return true
  elseif Settings.Subtlety.UsePriorityRotation == "On Bosses" and Target:IsInBossList() then
    return true
  elseif Settings.Subtlety.UsePriorityRotation == "Auto" then
    -- Zul Mythic
    if Target:NPCID() == 138967 then
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
  -- actions+=/variable,name=stealth_threshold,value=20+talent.vigor.rank*25+talent.thistle_tea*20+talent.shadowcraft*20
  return 20 + S.Vigor:TalentRank() * 25 + num(S.ThistleTea:IsAvailable()) * 20 + num(S.Shadowcraft:IsAvailable()) * 20
end

local function ShD_Threshold ()
  -- actions.stealth_cds=variable,name=shd_threshold,value=cooldown.shadow_dance.charges_fractional>=0.75+talent.double_dance
  return S.ShadowDance:ChargesFractional() >= 0.75 + BoolToInt(S.DoubleDance:IsAvailable())
end
local function SnD_Condition ()
  -- actions+=/variable,name=snd_condition,value=buff.slice_and_dice.up
  return Player:BuffUp(S.SliceandDice)
end
local function Skip_Rupture (ShadowDanceBuff)
  -- actions.finish+=/variable,name=skip_rupture,value=buff.thistle_tea.up&spell_targets.shuriken_storm=1|buff.shadow_dance.up&(spell_targets.shuriken_storm=1|dot.rupture.ticking&spell_targets.shuriken_storm>=2)|buff.darkest_night.up
  return Player:BuffUp(S.ThistleTea) and MeleeEnemies10yCount == 1 or Player:BuffUp(S.ShadowDanceBuff) and (MeleeEnemies10yCount == 1 or Target:DebuffUp(S.Rupture) and MeleeEnemies10yCount >= 2) or Player:BuffUp(S.DarkestNightBuff)
end
local function Skip_Rupture_NPC () -- Homebrew exclude for certain NPCs -- TODO Function to exclude these targets in "MeleeEnemies10yCount >= 5 and S.Rupture:AuraActiveCount() >= MeleeEnemies10yCount - 2" TODO: New NPC Ids for unimportant mobs.
  local NPCID = Target:NPCID() 
   -- Rise
  return NPCID == 206351 or NPCID == 206352 or NPCID == 203763 or NPCID == 203799 or NPCID == 203857 or NPCID == 203688 or NPCID == 205265
   -- Fall 
      or NPCID == 204536 or NPCID == 204918
   -- WM
      or NPCID == 135052 or NPCID == 134024 or NPCID == 136330 or NPCID == 133361 or NPCID == 131669
   -- BRH
      or NPCID == 99664 or NPCID == 98677 or NPCID == 102781
   -- AD
      or NPCID == 128435 or NPCID == 127315 or NPCID == 259205 or NPCID == 125828
   -- EB
      or NPCID == 81638
   -- DHT
      or NPCID == 109908 or NPCID == 107288 or NPCID == 100529 or NPCID == 101074
   -- ToT
      or NPCID == 429037 or NPCID == 39960 or NPCID == 213607 or NPCID == 213219 or NPCID == 40923
   -- Affixes
      or NPCID == 204560 or NPCID == 174773
   -- Raid
      or NPCID == 210231 or NPCID == 207341 or NPCID == 208459 or NPCID == 208461 or NPCID == 214441 or NPCID == 211306 or NPCID == 214608 or NPCID == 202969 or NPCID == 202971 or NPCID == 194991 or NPCID == 194990 or NPCID == 191714 or NPCID == 194647 or NPCID == 189233 or NPCID == 187638 or NPCID == 191510
end
local function Ruptures_Before_Flag ()
  -- actions.cds=variable,name=ruptures_before_flag,value=variable.priority_rotation|spell_targets<=4|talent.invigorating_shadowdust&!talent.follow_the_blood|(talent.replicating_shadows&(spell_targets>=5&active_dot.rupture>=spell_targets-2))|!talent.replicating_shadows -- If NPC exlucde causes issues with this, I will look at this again (for example, a boss spawning 100 trash adds, Anduiun for example, based on this, the script would not execute Flag, and there no CDs would be used (which is retarded))
  return PriorityRotation or MeleeEnemies10yCount <= 4 or Player:BuffUp(S.ShadowDanceBuff) or S.InvigoratingShadowdust:IsAvailable() and not S.FollowTheBlood:IsAvailable() or (S.ReplicatingShadows:IsAvailable() and (MeleeEnemies10yCount >= 5 and S.Rupture:AuraActiveCount() >= MeleeEnemies10yCount - 2)) or not S.ReplicatingShadows:IsAvailable()
end
local function CB ()
  -- actions.stealth_cds+=/variable,name=cb,value=!talent.cold_blood|cooldown.cold_blood.remains<4|cooldown.cold_blood.remains>10 to be deleted
  return not S.ColdBlood:IsAvailable() or S.ColdBlood:CooldownRemains() < 4 or S.ColdBlood:CooldownRemains() > 10
end
local function Used_For_Danse(Spell)
  return Player:BuffUp(S.ShadowDanceBuff) and Spell:TimeSinceLastCast() < S.ShadowDance:TimeSinceLastCast()
end
local function Secret_Condition ()
  -- actions.finish=variable,name=secret_condition,value=((buff.danse_macabre.stack>=2+!talent.deathstalkers_mark)|!talent.danse_macabre|(talent.unseen_blade&buff.shadow_dance.up&buff.escalating_blade.stack>=2))
  return ((Player:BuffStack(S.DanseMacabreBuff) >= 2 + num(not S.DeathStalkersMark:IsAvailable())) or not S.DanseMacabre:IsAvailable() or (S.UnseenBlade:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) and Player:BuffStack(S.EscalatingBlade) >= 2))
end
local function Trinket_Sync_Slot ()
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=1,if=trinket.1.has_stat.any_dps&(!trinket.2.has_stat.any_dps|trinket.1.cooldown.duration>=trinket.2.cooldown.duration)
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=2,if=trinket.2.has_stat.any_dps&(!trinket.1.has_stat.any_dps|trinket.2.cooldown.duration>trinket.1.cooldown.duration)
  local TrinketSyncSlot = 0

  if trinket1:HasStatAnyDps() and (not trinket2:HasStatAnyDps() or trinket1:Cooldown() >= trinket1:Cooldown()) then
    TrinketSyncSlot = 1
  elseif trinket2:HasStatAnyDps() and (not trinket1:HasStatAnyDps() or trinket2:Cooldown() > trinket2:Cooldown()) then
    TrinketSyncSlot = 2
  end

  return TrinketSyncSlot
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
  if StealthSpell and StealthSpell:ID() == S.ShadowDance:ID() then
    ShadowDanceBuff = true
    ShadowDanceBuffRemains = 6 + (S.ImprovedShadowDance:IsAvailable() and 2 or 0)
    if S.TheFirstDance:IsAvailable() then
      FinishComboPoints = mathmin(Player:ComboPointsMax(), ComboPoints + 4)
    end
  end

  local SkipRupture = Skip_Rupture(ShadowDanceBuff)
  -- actions.finish+=/rupture,if=!dot.rupture.ticking&target.time_to_die-remains>6 NOTE: Never use Rupture in Dance/Maybe add a check for 1 or 2 Targets in Raid? Will see
  if S.Rupture:IsCastable() then
      if not Target:DebuffUp(S.Rupture) and Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) then
          if (not Skip_Rupture_NPC() or PriorityRotation) and (not Player:BuffUp(S.ShadowDanceBuff) or PriorityRotation) then
              if ReturnSpellOnly then
                  return S.Rupture
              else
                  if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture Not Up" end
                  SetPoolingFinisher(S.Rupture)
              end
          end
      end
  end
  -- actions.finish+=/rupture,if=(!variable.skip_rupture|variable.priority_rotation)&target.time_to_die-remains>6&refreshable
  if ((not ShadowDanceBuff and not SkipRupture and not Skip_Rupture_NPC()) or PriorityRotation) and S.Rupture:IsCastable() then
    if TargetInMeleeRange
      and (Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid())
      and Rogue.CanDoTUnit(Target, RuptureDMGThreshold)
      and Target:DebuffRefreshable(S.Rupture, RuptureThreshold) then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture Refresh" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- actions.finish+=/coup_de_grace,if=debuff.fazed.up&(buff.shadow_dance.up|(buff.symbols_of_death.up&cooldown.shadow_dance.charges_fractional<=0.85))
  if S.CoupDeGrace:IsCastable() and TargetInMeleeRange and Target:DebuffUp(S.FazedDebuff) and (ShadowDanceBuff or (Player:BuffUp(S.SymbolsofDeath) and S.ShadowDance:ChargesFractional() <= 0.85)) then
    if ReturnSpellOnly then
      return S.CoupDeGrace
    else
      if S.CoupDeGrace:IsReady() and HR.Cast(S.CoupDeGrace) then return "Cast Coup De Grace 1" end
      SetPoolingFinisher(S.CoupDeGrace)
    end
  end
  -- actions.finish+=/cold_blood,if=variable.secret_condition&cooldown.secret_technique.ready
  if S.ColdBlood:IsCastable() and Secret_Condition() and S.SecretTechnique:IsCastable() then
    if Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood then
      HR.Cast(S.ColdBlood, Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood)
    else
      if ReturnSpellOnly then return S.ColdBlood end
      if HR.Cast(S.ColdBlood) then return "Cast Cold Blood (SecTec)" end
    end
  end
  -- actions.finish+=/secret_technique,if=variable.secret_condition&(!talent.cold_blood|cooldown.cold_blood.remains>buff.shadow_dance.remains-2|!talent.improved_shadow_dance)
  -- Attention: Due to the SecTec/ColdBlood interaction, this adaption has additional checks not found in the APL string 
  if S.SecretTechnique:IsCastable() and Secret_Condition()
      and (not S.ColdBlood:IsAvailable() or (Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood and S.ColdBlood:IsCastable())
      or Player:BuffUp(S.ColdBlood) or S.ColdBlood:CooldownRemains() > ShadowDanceBuffRemains - 2 or not S.ImprovedShadowDance:IsAvailable()) then
      if ReturnSpellOnly then return S.SecretTechnique end
      if HR.Cast(S.SecretTechnique) then return "Cast Secret Technique" end
  end

  if not ShadowDanceBuff and not SkipRupture and not Skip_Rupture_NPC() and S.Rupture:IsCastable() then
    -- actions.finish+=/rupture,cycle_targets=1,if=!variable.skip_rupture&!variable.priority_rotation&spell_targets.shuriken_storm>=2&target.time_to_die>=(2*combo_points)&refreshable (if not Player:BuffUp(S.ShadowDanceBuff) instead of Skip_Rupture as it does not work correctly.)
    if not ReturnSpellOnly and HR.AoEON() and not PriorityRotation and MeleeEnemies10yCount >= 2 then
      local function Evaluate_Rupture_Target(TargetUnit)
        return Everyone.CanDoTUnit(TargetUnit, RuptureDMGThreshold)
          and TargetUnit:DebuffRefreshable(S.Rupture, RuptureThreshold)
      end
      SuggestCycleDoT(S.Rupture, Evaluate_Rupture_Target, (2 * FinishComboPoints), MeleeEnemies5y)
    end
  end
  -- actions.finish+=/rupture,if=!variable.skip_rupture&buff.finality_rupture.up&(cooldown.symbols_of_death.remains<=3|buff.symbols_of_death.up) note: rupture is not longer inside of shadow dance is because Nightstalker got removed
  if S.Rupture:IsCastable() and not ShadowDanceBuff and Player:BuffUp(S.FinalityRuptureBuff) and not SkipRupture and not Skip_Rupture_NPC() and (S.SymbolsofDeath:CooldownRemains() <= 3 or Player:BuffUp(S.SymbolsofDeath)) then
    if TargetInMeleeRange then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsReady() and HR.Cast(S.Rupture) then return "Cast Rupture (Finality)" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  -- # DS BP
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&talent.deathstalkers_mark&spell_targets>=3&!buff.darkest_night.up
  if S.BlackPowder:IsCastable() and not PriorityRotation and S.DeathStalkersMark:IsAvailable() and MeleeEnemies10yCount >= 3 and not Player:BuffUp(S.DarkestNightBuff) then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsCastable() and HR.Cast(S.BlackPowder) then return "Cast Black Powder DS" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end
  -- # TS BP
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&talent.unseen_blade&((buff.escalating_blade.stack=4&!buff.shadow_dance.up)|spell_targets>=3&!buff.flawless_form.up|(!used_for_danse&buff.shadow_dance.up&talent.shuriken_tornado&spell_targets>=3))
  if S.BlackPowder:IsCastable() and not PriorityRotation and S.UnseenBlade:IsAvailable() and ((Player:BuffStack(S.EscalatingBlade) == 4 and not ShadowDanceBuff) or MeleeEnemies10yCount >= 3 and not Player:BuffUp(S.FlawlessFormBuff) or (not Used_For_Danse(S.BlackPowder) and ShadowDanceBuff and S.ShurikenTornado:IsAvailable() and MeleeEnemies10yCount >= 3)) then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsCastable() and HR.Cast(S.BlackPowder) then return "Cast Black Powder TS" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end
  -- Normal BP for leveling purposes
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&spell_targets>=3
  if S.BlackPowder:IsCastable() and not PriorityRotation and MeleeEnemies10yCount >= 3 and not S.UnseenBlade:IsAvailable() and not S.DeathStalkersMark:IsAvailable() then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsCastable() and HR.Cast(S.BlackPowder) then return "Cast Black Powder No DS or TS" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end
  -- actions.finish+=/coup_de_grace,if=debuff.fazed.up
  if S.CoupDeGrace:IsCastable() and TargetInMeleeRange and Target:DebuffUp(S.FazedDebuff) then
    if ReturnSpellOnly then
      return S.CoupDeGrace
    else
      if S.CoupDeGrace:IsReady() and HR.Cast(S.CoupDeGrace) then return "Cast Coup De Grace" end
      SetPoolingFinisher(S.CoupDeGrace)
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

  -- actions.stealthed=shadowstrike,if=talent.deathstalkers_mark&!debuff.deathstalkers_mark.up&!buff.darkest_night.up
  if ShadowstrikeIsCastable and S.DeathStalkersMark:IsAvailable() and not Target:DebuffUp(S.DeathStalkersMarkDebuff) and not Player:BuffUp(S.DarkestNightBuff) then
    if ReturnSpellOnly then
      return S.Shadowstrike
    else
      if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike (Stealth)" end
    end
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=buff.darkest_night.up&combo_points==cp_max_spend
  if Player:BuffUp(S.DarkestNightBuff) and ComboPoints == Rogue.CPMaxSpend() then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=effective_combo_points>=cp_max_spend&!buff.darkest_night.up
  if StealthEffectiveComboPoints >= Rogue.CPMaxSpend() and not Player:BuffUp(S.DarkestNightBuff) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=buff.shuriken_tornado.up&combo_points.deficit<=2&!buff.darkest_night.up
  if Player:BuffUp(S.ShurikenTornado) and StealthComboPointsDeficit <= 2 and not Player:BuffUp(S.DarkestNightBuff) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- actions.stealthed+=/call_action_list,name=finish,if=(combo_points.deficit<=1+talent.deathstalkers_mark)&!buff.darkest_night.up 
  if (StealthComboPointsDeficit <= 1 + num(S.DeathStalkersMark:IsAvailable())) and not Player:BuffUp(S.DarkestNightBuff) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end

  -- # Use shadowstrike for Danse Macabre on aoe and for Trickster use it instead of storm on 2+ targets
  -- actions.stealthed+=/shadowstrike,if=(!used_for_danse&buff.shadow_blades.up)|(talent.unseen_blade&spell_targets>=2)
  if ShadowstrikeIsCastable and (not Used_For_Danse(S.Shadowstrike) and Player:BuffUp(S.ShadowBlades)) or (S.UnseenBlade:IsAvailable() and MeleeEnemies10yCount >= 2) then
      if ReturnSpellOnly then
          return S.Shadowstrike
      else
          if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike (Danse or Trickster)" end
      end
  end
  -- actions.stealthed+=/shuriken_storm,if=!buff.premeditation.up&spell_targets>=4
  if HR.AoEON() and S.ShurikenStorm:IsCastable() and not PremeditationBuff and MeleeEnemies10yCount >= 4 then
      if ReturnSpellOnly then
          return S.ShurikenStorm
      else
          if HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
      end
  end
  -- actions.stealthed+=/gloomblade,if=buff.lingering_shadow.remains>=10&buff.shadow_blades.up&spell_targets=1
  if S.Gloomblade:IsCastable() and Player:BuffRemains(S.LingeringShadowBuff) >= 10 and Player:BuffUp(S.ShadowBlades) and MeleeEnemies10yCount == 1 then
      if ReturnSpellOnly then
          return S.Gloomblade
      else
          if HR.Cast(S.Gloomblade) then return "Cast Gloomblade" end
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
    if HR.Cast(S.Vanish, Settings.CommonsOGCD.OffGCDasOffGCD.Vanish) then return "Cast Vanish" end
    return false
  elseif StealthSpell:ID() == S.Shadowmeld:ID() and (not Settings.Subtlety.StealthMacro.Shadowmeld or not MacroAbility) then
    if HR.Cast(S.Shadowmeld, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Shadowmeld" end
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
local function CDs (EnergyThreshold)

  local SnDCondition = SnD_Condition()
  local PremeditationBuff = Player:BuffUp(S.PremeditationBuff) or (StealthSpell and S.Premeditation:IsAvailable())
  -- actions.cds+=/vanish,if=!variable.shd_threshold&(cooldown.flagellation.remains>=60|!talent.flagellation)&(cooldown.symbols_of_death.remains>3|!set_bonus.tier30_2pc)&(cooldown.secret_technique.remains>=10|!talent.secret_technique)
  if Settings.Subtlety.VanishafterSecret and S.Vanish:IsCastable() and S.InvigoratingShadowdust:IsAvailable() and (S.Flagellation:CooldownRemains() >= 60 or not S.Flagellation:IsAvailable()) and (S.SecretTechnique:CooldownRemains() >= 10) then
    ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
    if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
  end

  -- actions.cds+=/cold_blood,if=!talent.secret_technique&combo_points>=6
  if S.ColdBlood:IsCastable() and not S.SecretTechnique:IsAvailable() and ComboPoints >= 6 then
    if HR.Cast(S.ColdBlood, Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood) then return "Cast Cold Blood" end
  end

  if TargetInMeleeRange then
    -- actions.cds+=/sepsis,if=variable.snd_condition&(cooldown.shadow_blades.remains<=3&cooldown.symbols_of_death.remains<=3|fight_remains<=12)
    if S.Sepsis:IsCastable() and S.Sepsis:IsAvailable() and SnDCondition and (S.ShadowBlades:CooldownRemains() <= 3 and S.SymbolsofDeath:CooldownRemains() <= 3) then
      if HR.Cast(S.Sepsis, Settings.Subtlety.OffGCDasOffGCD.Sepsis) then return "Cast Sepsis" end
    end
    -- actions.cds+=/flagellation,target_if=max:target.time_to_die,if=variable.snd_condition&variable.ruptures_before_flag&combo_points>=5&target.time_to_die>10&(cooldown.shadow_blades.remains<=2|fight_remains<=24)&(!talent.invigorating_shadowdust|cooldown.symbols_of_death.remains<=3|buff.symbols_of_death.remains>3) note: delete "|fight_remains<=24"
    if S.Flagellation:IsCastable() and SnDCondition and Ruptures_Before_Flag() and ComboPoints >= 5 and Target:FilteredTimeToDie(">", 10) and (S.ShadowBlades:CooldownRemains() <= 2) and (not S.InvigoratingShadowdust:IsAvailable() or S.SymbolsofDeath:CooldownRemains() <= 3 or Player:BuffRemains(S.SymbolsofDeath) > 3) then
        if HR.Cast(S.Flagellation, Settings.Subtlety.OffGCDasOffGCD.Flagellation) then return "Cast Flagellation" end
    end
  end 

  -- #No Dust Symbols
  -- actions.cds+=/symbols_of_death,if=!talent.invigorating_shadowdust&variable.snd_condition&(buff.shadow_blades.up|cooldown.shadow_blades.remains>20) note: added Dungeonslice as a check so you can choose to hold blades.
  if S.SymbolsofDeath:IsCastable() and not S.InvigoratingShadowdust:IsAvailable() and SnDCondition and (Player:BuffUp(S.ShadowBlades) or S.ShadowBlades:CooldownRemains() > 20 or (S.ShadowBlades:IsCastable())) then
    if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath) then return "Cast Symbols of Death No Dust" end
  end
  -- # Dust Symbols
  -- actions.cds+=/symbols_of_death,if=talent.invigorating_shadowdust&variable.snd_condition&buff.symbols_of_death.remains<=3&!buff.the_rotten.up&(cooldown.flagellation.remains>10|cooldown.flagellation.up&cooldown.shadow_blades.remains>=20|buff.shadow_dance.remains>=2)
  if S.SymbolsofDeath:IsCastable() and S.InvigoratingShadowdust:IsAvailable() and SnDCondition and Player:BuffRemains(S.SymbolsofDeath) <= 3 and not Player:BuffUp(S.TheRottenBuff) and (S.Flagellation:CooldownRemains() > 10 or S.Flagellation:IsCastable() and S.ShadowBlades:CooldownRemains() >= 20 or Player:BuffRemains(S.ShadowDanceBuff) >= 2) then
     if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath) then return "Cast Symbols of Death With Dust" end
  end

  if HR.CDsON() then
    -- actions.cds+=/shadow_blades,if=variable.snd_condition&combo_points<=4&(buff.flagellation_buff.up|!talent.flagellation)
    if S.ShadowBlades:IsCastable() then
      if SnDCondition and ComboPoints <= 4 and (Player:BuffUp(S.Flagellation) or not S.Flagellation:IsAvailable()) then 
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades) then return "Cast Shadow Blades" end
      end
    end
    -- actions.cds+=/echoing_reprimand,if=variable.snd_condition&combo_points.deficit>=3&(!talent.the_rotten|!talent.reverberation|buff.shadow_dance.up)
    if S.EchoingReprimand:IsCastable() and SnDCondition and ComboPointsDeficit >= 3 and (not S.TheRotten:IsAvailable() or not S.Reverberation:IsAvailable() or Player:BuffUp(S.ShadowDanceBuff)) then
      if HR.Cast(S.EchoingReprimand, Settings.CommonsOGCD.GCDasOffGCD.EchoingReprimand) then return "Cast Echoing Reprimand" end
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
    -- actions.cds+=/vanish,if=buff.shadow_dance.up&talent.invigorating_shadowdust&talent.unseen_blade&(combo_points.deficit>1)&(cooldown.flagellation.remains>=60|!talent.flagellation)&(cooldown.secret_technique.remains>=10&!raid_event.adds.up)
    if S.Vanish:IsCastable() and Player:BuffUp(S.ShadowDanceBuff) and S.InvigoratingShadowdust:IsAvailable() and S.UnseenBlade:IsAvailable() and (ComboPointsDeficit > 1) and (S.Flagellation:CooldownRemains() >= 60 or not S.Flagellation:IsAvailable()) and (S.SecretTechnique:CooldownRemains() >= 10) then
       ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
       if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
    end
    -- actions.cds+=/shadow_dance,if=!buff.shadow_dance.up&fight_remains<=8+talent.subterfuge.enabled
    if S.ShadowDance:IsCastable() and MayBurnShadowDance() and not Player:BuffUp(S.ShadowDanceBuff) and HL.BossFilteredFightRemains("<=", 8) then
      ShouldReturn = StealthMacro(S.ShadowDance)
      if ShouldReturn then return "Shadow Dance Macro (Low TTD) " .. ShouldReturn end
    end
    -- actions.cds+=/shadow_dance,if=!buff.shadow_dance.up&talent.invigorating_shadowdust&talent.deathstalkers_mark&buff.shadow_blades.up&(buff.subterfuge.up&spell_targets>=4|buff.subterfuge.remains>=3)
    if S.ShadowDance:IsCastable() and not Player:BuffUp(S.ShadowDanceBuff) and S.InvigoratingShadowdust:IsAvailable() and S.DeathStalkersMark:IsAvailable() and Player:BuffUp(S.ShadowBlades) and (Player:BuffUp(S.SubterfugeBuff) and MeleeEnemies10yCount >= 4 or Player:BuffRemains(S.SubterfugeBuff) >= 3) then
        ShouldReturn = StealthMacro(S.ShadowDance, EnergyThreshold)
        if ShouldReturn then return "ShadowDance Macro " .. ShouldReturn end
    end
    -- actions.cds+=/shadow_dance,if=!buff.shadow_dance.up&talent.unseen_blade&talent.invigorating_shadowdust&dot.rupture.ticking&variable.snd_condition&(buff.symbols_of_death.remains>=6&!buff.flagellation_buff.up|buff.symbols_of_death.up&buff.shadow_blades.up|buff.shadow_blades.up&!talent.invigorating_shadowdust)&(cooldown.secret_technique.remains<10+12*!talent.invigorating_shadowdust|buff.shadow_blades.up)&(!talent.the_first_dance|(combo_points.deficit>=7&!buff.shadow_blades.up|buff.shadow_blades.up)) note: !buff.flagellation_buff.up is a dmg loss on old tier set with M+ Brew builds
    if S.ShadowDance:IsCastable() and not Player:BuffUp(S.ShadowDanceBuff) and S.UnseenBlade:IsAvailable() and S.InvigoratingShadowdust:IsAvailable() and Target:DebuffUp(S.Rupture) and SnDCondition and (Player:BuffRemains(S.SymbolsofDeath) >= 6 and not Player:BuffUp(S.Flagellation) or Player:BuffUp(S.SymbolsofDeath) and Player:BuffUp(S.ShadowBlades) or Player:BuffUp(S.ShadowBlades) and not S.InvigoratingShadowdust:IsAvailable()) and (S.SecretTechnique:CooldownRemains() < 10 + 12 * BoolToInt(not S.InvigoratingShadowdust:IsAvailable()) or Player:BuffUp(S.ShadowBlades)) and (not S.TheFirstDance:IsAvailable() or (ComboPointsDeficit >= 7 and not Player:BuffUp(S.ShadowBlades) or Player:BuffUp(S.ShadowBlades))) then
        ShouldReturn = StealthMacro(S.ShadowDance, EnergyThreshold)
        if ShouldReturn then return "ShadowDance Macro " .. ShouldReturn end
    end
    -- actions.cds+=/goremaws_bite,if=variable.snd_condition&combo_points.deficit>=3&(!cooldown.shadow_dance.up|talent.double_dance&buff.shadow_dance.up&!talent.invigorating_shadowdust|spell_targets.shuriken_storm<4&!talent.invigorating_shadowdust|talent.the_rotten|raid_event.adds.up)
    if S.GoremawsBite:IsCastable() then
      if SnDCondition and ComboPointsDeficit >= 3 and (not S.ShadowDance:CooldownUp() or 
        (S.DoubleDance:IsAvailable() and Player:BuffUp(S.ShadowDanceBuff) and not S.InvigoratingShadowdust:IsAvailable()) or 
        (MeleeEnemies10yCount < 4 and not S.InvigoratingShadowdust:IsAvailable()) or S.TheRotten:IsAvailable()) then
        if HR.Cast(S.GoremawsBite) then return "Cast GoremawsBite" end
      end
    end
    -- CUSTOM CONDITIONS
    
    -- # Use tea during shadowblade dances and dances in which cold blood is up for sectech
    -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&(buff.shadow_dance.remains>=4&buff.shadow_blades.up|buff.shadow_dance.remains>=4&cooldown.cold_blood.remains<=3)|fight_remains<=(6*cooldown.thistle_tea.charges)
    if S.ThistleTea:IsCastable() and not Player:BuffUp(S.ThistleTea) and (Player:BuffRemains(S.ShadowDanceBuff) >= 4 and Player:BuffUp(S.ShadowBlades) or Player:BuffRemains(S.ShadowDanceBuff) >= 4 and S.ColdBlood:CooldownRemains() <= 3) then
        if HR.Cast(S.ThistleTea, Settings.CommonsOGCD.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea (Max Stacks during Shadow Dance)" end
      end
    -- actions.cds+=/potion,if=buff.bloodlust.react|fight_remains<30|buff.symbols_of_death.up&(buff.shadow_blades.up|cooldown.shadow_blades.remains<=10)
    if Settings.Commons.Enabled.Potions then
      local PotionSelected = Everyone.PotionSelected()
      if PotionSelected and PotionSelected:IsReady() and (Player:BloodlustUp() or HL.BossFilteredFightRemains("<", 30) or Player:BuffUp(S.SymbolsofDeath)
        and (Player:BuffUp(S.ShadowBlades) or S.ShadowBlades:CooldownRemains() <= 10)) then
        if Cast(PotionSelected, nil, Settings.CommonsDS.DisplayStyle.Potions) then return "Cast Potion"; end
      end
    end
    -- Racials
    -- actions.cds+=/variable,name=racial_sync,value=buff.shadow_blades.up|!talent.shadow_blades&buff.symbols_of_death.up|fight_remains<20
    if Player:BuffUp(S.ShadowBlades) or (not S.ShadowBlades:IsAvailable() and Player:BuffUp(S.SymbolsofDeath)) or HL.BossFilteredFightRemains("<", 20) then
      -- actions.cds+=/blood_fury,if=variable.racial_sync
      if S.BloodFury:IsCastable() then
        if HR.Cast(S.BloodFury, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Blood Fury" end
      end
      -- actions.cds+=/berserking,if=variable.racial_sync
      if S.Berserking:IsCastable() then
        if HR.Cast(S.Berserking, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Berserking" end
      end
      -- actions.cds+=/fireblood,if=variable.racial_sync&buff.shadow_dance.up
      if S.Fireblood:IsCastable() and Player:BuffUp(S.ShadowDanceBuff) then
        if HR.Cast(S.Fireblood, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Fireblood" end
      end
      -- actions.cds+=/ancestral_call,if=variable.racial_sync
      if S.AncestralCall:IsCastable() then
        if HR.Cast(S.AncestralCall, Settings.CommonsOGCD.OffGCDasOffGCD.Racials) then return "Cast Ancestral Call" end
      end
    end
  end

  return false
end

-- # Items
local function Items()
  if Settings.Commons.Enabled.Trinkets then
    -- actions.items+=/use_item,name=treacherous_transmitter,if=buff.shadow_blades.up|fight_remains<=15
    if I.TreacherousTransmitter:IsEquippedAndReady() then
      if Player:BuffUp(S.ShadowBlades) then
        if Cast(I.TreacherousTransmitter, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Treacherous Transmitter" end
      end
    end

    --actions.items+=/use_item,name=imperfect_ascendancy_serum,use_off_gcd=1,if=dot.rupture.ticking&buff.flagellation_buff.up
    if I.ImperfectAscendancySerum:IsEquippedAndReady() then
      if  Target:DebuffUp(S.Rupture) and Player:BuffUp(S.Flagellation) then
        if Cast(I.ImperfectAscendancySerum, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Imperfect Ascendancy Serum" end
      end
    end

    local TrinketSpell
    local TrinketRange = 100
    --actions.items+=/use_items,slots=trinket1,if=(variable.trinket_sync_slot=1&(buff.shadow_blades.up|(1+cooldown.shadow_blades.remains)>=trinket.1.cooldown.duration|fight_remains<=20)|(variable.trinket_sync_slot=2&(!trinket.2.cooldown.ready&!buff.shadow_blades.up&cooldown.shadow_blades.remains>20))|!variable.trinket_sync_slot)
    if trinket1 then
      TrinketSpell = trinket1:OnUseSpell()
      TrinketRange = (TrinketSpell and TrinketSpell.MaximumRange > 0 and TrinketSpell.MaximumRange <= 100) and TrinketSpell.MaximumRange or 100
    end
    if trinket1:IsEquippedAndReady() then
      if not ValueIsInArray(OnUseExcludes, trinket1:ID()) and (Trinket_Sync_Slot() == 1 and (Player:BuffUp(S.ShadowBlades) or (1+S.ShadowBlades:CooldownRemains()) >= trinket1:CooldownRemains()) or (Trinket_Sync_Slot() == 2 and (not trinket2:IsReady() and not Player:BuffUp(S.ShadowBlades) and S.ShadowBlades:CooldownRemains() > 20)) or Trinket_Sync_Slot() == 0) then
          if Cast(trinket1, nil, Settings.CommonsDS.DisplayStyle.Trinkets, not Target:IsInRange(TrinketRange)) then return "Generic use_items for " .. trinket1:Name() end
      end
    end

    --actions.items+=/use_items,slots=trinket2,if=(variable.trinket_sync_slot=2&(buff.shadow_blades.up|(1+cooldown.shadow_blades.remains)>=trinket.2.cooldown.duration|fight_remains<=20)|(variable.trinket_sync_slot=1&(!trinket.1.cooldown.ready&!buff.shadow_blades.up&cooldown.shadow_blades.remains>20))|!variable.trinket_sync_slot)
    if trinket2 then
      TrinketSpell = trinket2:OnUseSpell()
      TrinketRange = (TrinketSpell and TrinketSpell.MaximumRange > 0 and TrinketSpell.MaximumRange <= 100) and TrinketSpell.MaximumRange or 100
    end
    if trinket2:IsEquippedAndReady() then
      if not ValueIsInArray(OnUseExcludes, trinket2:ID()) and (Trinket_Sync_Slot() == 2 and (Player:BuffUp(S.ShadowBlades) or (1+S.ShadowBlades:CooldownRemains()) >= trinket2:CooldownRemains()) or (Trinket_Sync_Slot() == 1 and (not trinket1:IsReady() and not Player:BuffUp(S.ShadowBlades) and S.ShadowBlades:CooldownRemains() > 20)) or Trinket_Sync_Slot() == 0) then
          if Cast(trinket2, nil, Settings.CommonsDS.DisplayStyle.Trinkets, not Target:IsInRange(TrinketRange)) then return "Generic use_items for " .. trinket2:Name() end
      end
    end
  end

  return false
end
-- # Stealth Cooldowns
local function Stealth_CDs (EnergyThreshold)
  if HR.CDsON() then
    -- # No Dust Vanish
    -- actions.stealth_cds=vanish,if=!talent.invigorating_shadowdust&!talent.subterfuge&combo_points.deficit>=3&(!dot.rupture.ticking|(buff.shadow_blades.up&buff.symbols_of_death.up)|talent.premeditation|fight_remains<10)
    if S.Vanish:IsCastable() and not DungeonSlice and not S.InvigoratingShadowdust:IsAvailable() and not S.Subterfuge:IsAvailable() and ComboPointsDeficit >= 3 and (not Target:DebuffUp(S.Rupture) or (Player:BuffUp(S.ShadowBlades) and Player:BuffUp(S.SymbolsofDeath)) or S.Premeditation:IsAvailable()) then
       ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
       if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
    end
    -- # Dust Vanish
    -- actions.stealth_cds+=/vanish,if=!buff.shadow_dance.up&talent.invigorating_shadowdust&talent.deathstalkers_mark&(combo_points.deficit>1|buff.shadow_blades.up)&(cooldown.flagellation.remains>=60|!talent.flagellation)&(cooldown.secret_technique.remains>=10) note: deleted "fight_remains<=(30*cooldown.vanish.charges)" deleted DeathStalkersMark check so it works with leveling
    if S.Vanish:IsCastable() and not Player:BuffUp(S.ShadowDanceBuff) and S.InvigoratingShadowdust:IsAvailable() and (ComboPointsDeficit > 1 or Player:BuffUp(S.ShadowBlades)) and (S.Flagellation:CooldownRemains() >= 60 or not S.Flagellation:IsAvailable()) and (S.SecretTechnique:CooldownRemains() >= 10) then
      ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
      if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
    end
  end
  if TargetInMeleeRange and S.ShadowDance:IsCastable() and HR.CDsON() then
    -- actions.stealth_cds+=/shadow_dance,if=dot.rupture.ticking&variable.snd_condition&(buff.symbols_of_death.remains>=6&!buff.flagellation_buff.up|buff.symbols_of_death.up&buff.shadow_blades.up|buff.shadow_blades.up&!talent.invigorating_shadowdust)&cooldown.secret_technique.remains<10+12*!talent.invigorating_shadowdust&(!talent.the_first_dance|(combo_points.deficit>=7&!buff.shadow_blades.up|buff.shadow_blades.up))
    if Target:DebuffUp(S.Rupture) and SnD_Condition() and (Player:BuffRemains(S.SymbolsofDeath) >= 6 and not Player:BuffUp(S.Flagellation) or Player:BuffUp(S.SymbolsofDeath) and Player:BuffUp(S.ShadowBlades) or Player:BuffUp(S.ShadowBlades) and not S.InvigoratingShadowdust:IsAvailable()) and S.SecretTechnique:CooldownRemains() < 10 + 12 * num(not S.InvigoratingShadowdust:IsAvailable()) and (not S.TheFirstDance:IsAvailable() or (ComboPointsDeficit >= 7 and not Player:BuffUp(S.ShadowBlades) or Player:BuffUp(S.ShadowBlades))) then
        ShouldReturn = StealthMacro(S.ShadowDance, EnergyThreshold)
        if ShouldReturn then return "ShadowDance Macro " .. ShouldReturn end
    end
  end
  -- # No Dust subterfuge vanish
  -- actions.stealth_cds+=/vanish,if=!talent.invigorating_shadowdust&talent.subterfuge&combo_points.deficit>=3&(buff.symbols_of_death.up|cooldown.symbols_of_death.remains>=3)
  if S.Vanish:IsCastable() and not S.InvigoratingShadowdust:IsAvailable() and S.Subterfuge:IsAvailable() and ComboPointsDeficit >= 3 and (Player:BuffUp(S.SymbolsofDeath) or S.SymbolsofDeath:CooldownRemains() >= 3) then
     ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
     if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
  end
  -- actions.stealth_cds+=/shadowmeld,if=energy>=40&combo_points.deficit>3
  if S.Shadowmeld:IsCastable() and TargetInMeleeRange and not Player:IsMoving() and ComboPointsDeficit > 3 then
    -- actions.stealth_cds+=/pool_resource,for_next=1,extra_amount=40, if=race.night_elf
    if Player:Energy() < 40 then
      if HR.CastPooling(S.Shadowmeld, Player:EnergyTimeToX(40)) then return "Pool for Shadowmeld" end
    end
    ShouldReturn = StealthMacro(S.Shadowmeld, EnergyThreshold)
    if ShouldReturn then return "Shadowmeld Macro " .. ShouldReturn end
  end

  return false
end

-- # Builders
local function Build (EnergyThreshold)
  local ThresholdMet = not EnergyThreshold or Player:EnergyPredicted() >= EnergyThreshold
  -- actions.build=shuriken_storm,if=spell_targets>=2+(talent.gloomblade&buff.lingering_shadow.remains>=6|buff.perforated_veins.up)-(!debuff.find_weakness.up&!talent.improved_backstab)&(buff.flawless_form.up|!talent.unseen_blade)
  if HR.AoEON() and S.ShurikenStorm:IsCastable() then
    if MeleeEnemies10yCount >= 2 + BoolToInt(S.Gloomblade:IsAvailable() and Player:BuffRemains(S.LingeringShadowBuff) >= 6 or Player:BuffUp(S.PerforatedVeinsBuff)) - BoolToInt(not Target:DebuffUp(S.FindWeaknessDebuff) and not S.ImprovedBackstab:IsAvailable()) and (Player:BuffUp(S.FlawlessFormBuff) or not S.UnseenBlade:IsAvailable()) then
      if ThresholdMet and HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
      SetPoolingAbility(S.ShurikenStorm, EnergyThreshold)
    end
  end
  -- Deathstalker shuriken storm on single target
  -- actions.build+=/shuriken_storm,if=buff.clear_the_witnesses.up&(!buff.symbols_of_death.up|!talent.inevitability)&(buff.lingering_shadow.remains<=6|!talent.lingering_shadow)
  if S.ShurikenStorm:IsCastable() and Player:BuffUp(S.ClearTheWitnessesBuff) then
    if (not Player:BuffUp(S.SymbolsofDeath) or not S.Inevitability:IsAvailable()) and (Player:BuffRemains(S.LingeringShadowBuff) <= 6 or not S.LingeringShadow:IsAvailable()) then
      if ThresholdMet and HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm (Single Target)" end
      SetPoolingAbility(S.ShurikenStorm, EnergyThreshold)
    end
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
  MeleeRange = 5
  AoERange = 10
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
  DungeonSlice = Player:IsInParty() and Player:IsInDungeonArea() and not Player:IsInRaid()
  InRaid = Player:IsInRaid() and not Player:IsInDungeonArea()

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
    ShouldReturn = Everyone.Interrupt(S.Kick, Settings.CommonsDS.DisplayStyle.Interrupts, Interrupts)
    if ShouldReturn then return ShouldReturn end

    -- Blind
    if S.Blind:IsCastable() and Target:IsInterruptible() and (Target:NPCID() == 204560 or Target:NPCID() == 174773) then
       if S.Blind:IsReady() and HR.Cast(S.Blind, Settings.CommonsOGCD.GCDasOffGCD.Blind) then return "Blind to CC Affix" end
    end

    -- Maybe do a KidneyShot check for important adds. Archer in Hold for example.
    -- # Check CDs at first
    -- actions=call_action_list,name=cds
    ShouldReturn = CDs()
    if ShouldReturn then return "CDs: " .. ShouldReturn end

    -- actions+=/call_action_list,name=items
    ShouldReturn = Items()
    if ShouldReturn then return "Items: " .. ShouldReturn end

    -- actions+=/slice_and_dice,if=combo_points>=1&!buff.slice_and_dice.up
    if S.SliceandDice:IsCastable() and ComboPoints >= 1 and not SnD_Condition() then
       if HR.Cast(S.SliceandDice) then return "Cast Slice and Dice (Low Duration)" end
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

    -- # Check if you should use dance, vanish or shadowmeld to enter stealth
    -- actions+=/call_action_list,name=stealth_cds
    ShouldReturn = Stealth_CDs(StealthEnergyRequired)
    if ShouldReturn then return "Stealth CDs: " .. ShouldReturn end

    -- actions+=/call_action_list,name=finish,if=buff.darkest_night.up&combo_points==cp_max_spend
    -- actions+=/call_action_list,name=finish,if=effective_combo_points>=cp_max_spend&!buff.darkest_night.up
    -- # Finish at maximum or close to maximum combo point value
    -- actions+=/call_action_list,name=finish,if=(combo_points.deficit<=1+talent.deathstalkers_mark|fight_remains<=1&effective_combo_points>=3)&!buff.darkest_night.up
    -- # Finish at 4+ against 4 targets (outside stealth)
    -- actions+=/call_action_list,name=finish,if=spell_targets.shuriken_storm>=4&effective_combo_points>=4&!buff.darkest_night.up
    if Player:BuffUp(S.DarkestNightBuff) and EffectiveComboPoints == Rogue.CPMaxSpend()
      or (EffectiveComboPoints >= Rogue.CPMaxSpend() and not Player:BuffUp(S.DarkestNightBuff))
      or ((ComboPointsDeficit <= 1 + num(S.DeathStalkersMark:IsAvailable()) or HL.BossFilteredFightRemains("<=", 1) and EffectiveComboPoints >= 3) and not Player:BuffUp(S.DarkestNightBuff))
      or (MeleeEnemies10yCount >= 4 and EffectiveComboPoints >= 4 and not Player:BuffUp(S.DarkestNightBuff)) then
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
        if HR.Cast(S.ArcaneTorrent, Settings.CommonsOGCD.GCDasOffGCD.Racials) then return "Cast Arcane Torrent" end
      end
      -- actions+=/arcane_pulse
      if S.ArcanePulse:IsReady() and TargetInMeleeRange then
        if HR.Cast(S.ArcanePulse, Settings.CommonsOGCD.GCDasOffGCD.Racials) then return "Cast Arcane Pulse" end
      end
      -- actions+=/lights_judgment
      if S.LightsJudgment:IsReady() then
        if HR.Cast(S.LightsJudgment, Settings.CommonsOGCD.GCDasOffGCD.Racials) then return "Cast Lights Judgment" end
      end
      -- actions+=/bag_of_tricks
      if S.BagofTricks:IsReady() then
        if HR.Cast(S.BagofTricks, Settings.CommonsOGCD.GCDasOffGCD.Racials) then return "Cast Bag of Tricks" end
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
  S.Rupture:RegisterAuraTracking()

  HR.Print("You are using a fork [Version 2.0]: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl")
end

HR.SetAPL(261, APL, Init)

-- Last Update 2023-12-02
-- Using Fuus lasted posted APL in the TC-Subtlety, too lazy to copy :)

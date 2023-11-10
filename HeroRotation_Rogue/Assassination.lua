--- ============================ HEADER ============================
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
local CastLeftNameplate = HR.CastLeftNameplate
-- Num/Bool Helper Functions
local num = HR.Commons.Everyone.num
local bool = HR.Commons.Everyone.bool
-- Lua
local pairs = pairs
local mathfloor = math.floor
local mathmax = math.max

--- ============================ CONTENT ============================
--- ======= APL LOCALS =======
-- Commons
local Everyone = HR.Commons.Everyone
local Rogue = HR.Commons.Rogue

-- GUI Settings
local Settings = {
  General = HR.GUISettings.General,
  Commons = HR.GUISettings.APL.Rogue.Commons,
  Commons2 = HR.GUISettings.APL.Rogue.Commons2,
  Assassination = HR.GUISettings.APL.Rogue.Assassination
}

-- Spells
local S = Spell.Rogue.Assassination

-- Items
local I = Item.Rogue.Assassination
local OnUseExcludeTrinkets = {
  I.AlgetharPuzzleBox,
  I.MirrorOfFracturedTomorrows:ID(),
  I.AshesOfTheEmbersoul:ID(),
  I.WitherBarksBranch:ID(),
  I.BandolierOfTwistedBlades:ID(),
}

-- Enemies
local MeleeRange, AoERange, TargetInMeleeRange, TargetInAoERange
local Enemies30y, MeleeEnemies10y, MeleeEnemies10yCount, MeleeEnemies5y

-- Rotation Variables
local ShouldReturn
local BleedTickTime, ExsanguinatedBleedTickTime = 2 * Player:SpellHaste(), 1 * Player:SpellHaste()
local ComboPoints, ComboPointsDeficit
local RuptureThreshold, CrimsonTempestThreshold, RuptureDMGThreshold, GarroteDMGThreshold, RuptureDurationThreshold, RuptureTickTime, GarroteTickTime
local PriorityRotation
local ExsanguinateSyncRemains, PoisonedBleeds, EnergyRegenCombined, EnergyTimeToMaxCombined, EnergyRegenSaturated, SingleTarget
local TrinketSyncSlot = 0



-- Covenant and Legendaries
local Equipment = Player:GetEquipment()
local TrinketItem1 = Equipment[13] and Item(Equipment[13]) or Item(0)
local TrinketItem2 = Equipment[14] and Item(Equipment[14]) or Item(0)
local function SetTrinketVariables ()
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=1,if=trinket.1.has_stat.any_dps&(!trinket.2.has_stat.any_dps|trinket.1.cooldown.duration>=trinket.2.cooldown.duration)
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=2,if=trinket.2.has_stat.any_dps&(!trinket.1.has_stat.any_dps|trinket.2.cooldown.duration>trinket.1.cooldown.duration)
  if TrinketItem1:HasStatAnyDps() and (not TrinketItem2:HasStatAnyDps() or TrinketItem1:Cooldown() >= TrinketItem2:Cooldown()) then
    TrinketSyncSlot = 1
  elseif TrinketItem2:HasStatAnyDps() and (not TrinketItem1:HasStatAnyDps() or TrinketItem2:Cooldown() > TrinketItem1:Cooldown()) then
    TrinketSyncSlot = 2
  else
    TrinketSyncSlot = 0
  end
end
SetTrinketVariables()

HL:RegisterForEvent(function()
  Equipment = Player:GetEquipment()
  TrinketItem1 = Equipment[13] and Item(Equipment[13]) or Item(0)
  TrinketItem2 = Equipment[14] and Item(Equipment[14]) or Item(0)
  SetTrinketVariables()
end, "PLAYER_EQUIPMENT_CHANGED" )

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
      (1 + Player:VersatilityDmgPct()/100)
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
local function MasterAssassinRemains ()
  -- Currently stealthed (i.e. Aura)
  if Player:BuffRemains(S.MasterAssassinBuff) == 9999 then
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

local function ComputeImprovedGarrotePMultiplier ()
  if S.ImprovedGarrote:IsAvailable() and (Player:BuffUp(S.ImprovedGarroteAura, nil, true)
    or Player:BuffUp(S.ImprovedGarroteBuff, nil, true) or Player:BuffUp(S.SepsisBuff, nil, true)) then
    return 1.5
  end
  return 1
end
S.Garrote:RegisterPMultiplier(ComputeImprovedGarrotePMultiplier)

--- ======= HELPERS =======
-- Check if the Priority Rotation variable should be set
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
    end
  end

  return false
end

-- actions+=/variable,name=not_pooling,value=(dot.deathmark.ticking|dot.kingsbane.ticking|buff.shadow_dance.up|debuff.shiv.up|cooldown.thistle_tea.full_recharge_time<20)|(buff.envenom.up&buff.envenom.remains<=2)|energy.pct>=80|fight_remains<=90
local function not_pooling()
    return (Target:DebuffUp(S.Deathmark) or Target:DebuffUp(S.Kingsbane) or Player:BuffUp(S.ShadowDanceBuff) or Target:DebuffUp(S.ShivDebuff) or S.ThistleTea:FullRechargeTime() <= 20) or (Player:BuffUp(S.Envenom) and Player:BuffRemains(S.Envenom) <= 2) or Player:EnergyPercentage() >= 80 or HL.BossFilteredFightRemains("<=", 90)
end

-- actions+=/variable,name=sepsis_sync_remains,op=setif,condition=cooldown.deathmark.remains>cooldown.sepsis.remains&cooldown.deathmark.remains<fight_remains,value=cooldown.deathmark.remains,value_else=cooldown.sepsis.remains
local function SepsisSyncRemains()
  if S.Deathmark:CooldownRemains() > S.Sepsis:CooldownRemains()
    and (HL.BossFightRemainsIsNotValid() or HL.BossFilteredFightRemains("<", S.Deathmark:CooldownRemains())) then
    return S.Deathmark:CooldownRemains()
  end
  return S.Sepsis:CooldownRemains()
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

local function CheckWillWasteCooldown(ThisCooldownLength, OtherCooldownRemains, EffectDuration)
  local FightRemains = Target:TimeToDie()
  if not HL.BossFightRemainsIsNotValid() then
    FightRemains = HL.BossFightRemains()
  elseif FightRemains < EffectDuration then
    return false -- Bail out if we are not in a boss encounter and fighting a low-HP target
  end
  -- e.g. if=floor((fight_remains-30)%cooldown)>floor((fight_remains-30-cooldown.vendetta.remains)%cooldown)
  if mathfloor((FightRemains - EffectDuration) / ThisCooldownLength) >
    mathfloor((FightRemains - EffectDuration - OtherCooldownRemains) / ThisCooldownLength) then
    return true
  end
  return false
end

-- Serrated Bone Spike Cycle Targets
-- actions.direct+=/serrated_bone_spike,target_if=min:target.time_to_die+(dot.serrated_bone_spike_dot.ticking*600),if=variable.use_filler&!dot.serrated_bone_spike_dot.ticking
local function EvaluateSBSTargetIfConditionCondition(TargetUnit)
  if TargetUnit:DebuffUp(S.SerratedBoneSpikeDebuff) then
    return 1000000 -- Random big number
  end
  return TargetUnit:TimeToDie()
end
local function EvaluateSBSCondition(TargetUnit)
  return not TargetUnit:DebuffUp(S.SerratedBoneSpikeDebuff)
end

--- ======= ACTION LISTS =======
local function Racials ()
  -- actions.cds+=/blood_fury,if=debuff.vendetta.up
  if S.BloodFury:IsCastable() then
    if Cast(S.BloodFury, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Blood Fury" end
  end
  -- actions.cds+=/berserking,if=debuff.vendetta.up
  if S.Berserking:IsCastable() then
    if Cast(S.Berserking, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Berserking" end
  end
  -- actions.cds+=/fireblood,if=debuff.vendetta.up
  if S.Fireblood:IsCastable() then
    if Cast(S.Fireblood, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Fireblood" end
  end
  -- actions.cds+=/ancestral_call,if=debuff.vendetta.up
  if S.AncestralCall:IsCastable() then
    if Cast(S.AncestralCall, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Ancestral Call" end
  end

  return false
end

-- # Vanish Handling
local function Vanish ()
  if S.Vanish:IsCastable() and not Player:IsTanking(Target) then
    if not S.MasterAssassin:IsAvailable() and S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp()
      and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote)) then
      -- actions.vanish+=/vanish,if=!talent.master_assassin&talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&(debuff.deathmark.up|cooldown.deathmark.remains<4)&combo_points.deficit>=(spell_targets.fan_of_knives>?4)
      if (S.Deathmark:AnyDebuffUp() or S.Deathmark:CooldownRemains() < 4) and ComboPointsDeficit >= math.min(MeleeEnemies10yCount, 4) then
        -- actions.cds+=/pool_resource,for_next=1,extra_amount=45
        if Settings.Commons.ShowPooling and Player:EnergyPredicted() < 45 then
          if Cast(S.PoolEnergy) then return "Pool for Vanish (Garrote Deathmark)" end
        end
        if Cast(S.Vanish, Settings.Commons.OffGCDasOffGCD.Vanish) then return "Cast Vanish (Garrote Deathmark)" end
      end
      -- actions.vanish+=/vanish,if=!talent.master_assassin&talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&spell_targets.fan_of_knives>(3-talent.indiscriminate_carnage)
      if MeleeEnemies10yCount > (3 - BoolToInt(S.IndiscriminateCarnage:IsAvailable())) and (not S.IndiscriminateCarnage:IsAvailable() or S.IndiscriminateCarnage:CooldownUp()) then
        -- actions.cds+=/pool_resource,for_next=1,extra_amount=45
        if Settings.Commons.ShowPooling and Player:EnergyPredicted() < 45 then
          if Cast(S.PoolEnergy) then return "Pool for Vanish (Garrote)" end
        end
        if Cast(S.Vanish, Settings.Commons.OffGCDasOffGCD.Vanish) then return "Cast Vanish (Garrote)" end
      end
    end
    -- actions.vanish+=/vanish,if=!talent.improved_garrote&talent.master_assassin&!dot.rupture.refreshable&dot.garrote.remains>3&debuff.deathmark.up&(debuff.shiv.up|debuff.deathmark.remains<4|dot.sepsis.ticking)&dot.sepsis.remains<3
    if not S.ImprovedGarrote:IsAvailable() and S.MasterAssassin:IsAvailable() and not IsDebuffRefreshable(Target, S.Rupture) and Target:DebuffRemains(S.Garrote) > 3
       and Target:DebuffUp(S.Deathmark) and (Target:DebuffUp(S.ShivDebuff) or Target:DebuffRemains(S.Deathmark) < 4 or Target:DebuffUp(S.Sepsis)) and Target:DebuffRemains(S.Sepsis) < 3 then
       if Cast(S.Vanish, Settings.Commons.OffGCDasOffGCD.Vanish) then return "Cast Vanish (Master Assassin)" end
    end
    -- actions.vanish+=/vanish,if=talent.master_assassin&talent.kingsbane&dot.kingsbane.remains<=3&dot.kingsbane.ticking&debuff.deathmark.remains<=3&dot.deathmark.ticking
    if S.MasterAssassin:IsAvailable() and S.Kingsbane:IsAvailable()
       and Target:DebuffRemains(S.Kingsbane) <= 3 and Target:DebuffUp(S.Kingsbane)
       and Target:DebuffRemains(S.Deathmark) <= 3 and Target:DebuffUp(S.Deathmark) then
       if Cast(S.Vanish, Settings.Commons.OffGCDasOffGCD.Vanish) then return "Cast Vanish (Master Assassin with Kingsbane)" end
    end
  end
  if S.ShadowDance:IsCastable() then
    -- actions.vanish+=/shadow_dance,if=!talent.kingsbane&talent.improved_garrote&cooldown.garrote.up&(dot.garrote.pmultiplier<=1|dot.garrote.refreshable)&(debuff.deathmark.up|cooldown.deathmark.remains<12|cooldown.deathmark.remains>60)&combo_points.deficit>=(spell_targets.fan_of_knives>?4)
    if not S.Kingsbane:IsAvailable() and S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp() and (Target:PMultiplier(S.Garrote) <= 1 or IsDebuffRefreshable(Target, S.Garrote))
       and (S.Deathmark:AnyDebuffUp() or S.Deathmark:CooldownRemains() < 12 or S.Deathmark:CooldownRemains() > 60) and ComboPointsDeficit >= math.min(MeleeEnemies10yCount, 4) then
       if Cast(S.ShadowDance, Settings.Commons.OffGCDasOffGCD.ShadowDance) then return "Cast Shadow Dance (Garrote)" end
    end
    -- actions.vanish+=/shadow_dance,if=!talent.kingsbane&!talent.improved_garrote&talent.master_assassin&!dot.rupture.refreshable&dot.garrote.remains>3&(debuff.deathmark.up|cooldown.deathmark.remains>60)&(debuff.shiv.up|debuff.deathmark.remains<4|dot.sepsis.ticking)&dot.sepsis.remains<3
    if not S.Kingsbane:IsAvailable() and not S.ImprovedGarrote:IsAvailable() and S.MasterAssassin:IsAvailable() and not IsDebuffRefreshable(Target, S.Rupture)
       and Target:DebuffRemains(S.Garrote) > 3 and (Target:DebuffUp(S.Deathmark) or S.Deathmark:CooldownRemains() > 60)
       and (Target:DebuffUp(S.ShivDebuff) or Target:DebuffRemains(S.Deathmark) < 4 or Target:DebuffUp(S.Sepsis)) and Target:DebuffRemains(S.Sepsis) < 3 then
       if Cast(S.ShadowDance, Settings.Commons.OffGCDasOffGCD.ShadowDance) then return "Cast Shadow Dance (Master Assassin)" end
    end
  end
end

-- # Cooldowns
local function CDs ()
  if not TargetInAoERange then
    return
  end

  if not Player:StealthUp(true, false) and HR.CDsON() then
  -- actions.cds+=/sepsis,if=dot.rupture.ticking&dot.rupture.remains>20&(!talent.improved_garrote&dot.garrote.ticking|talent.improved_garrote&cooldown.garrote.up&dot.garrote.pmultiplier<=1)&(target.time_to_die>10|fight_remains<10)
    if S.Sepsis:IsCastable() and Target:DebuffUp(S.Rupture) and Target:DebuffRemains(S.Rupture) > 20
      and ((not S.ImprovedGarrote:IsAvailable() and Target:DebuffUp(S.Garrote)) 
      or (S.ImprovedGarrote:IsAvailable() and S.Garrote:CooldownUp() and Target:PMultiplier(S.Garrote) <= 1))
      and (Target:FilteredTimeToDie(">", 10) or Target:FilteredTimeToDie("<", 10)) then
      if Cast(S.Sepsis, nil, Settings.Commons.CovenantDisplayStyle) then return "Cast Sepsis" end
    end

    -- actions.cds+=/use_item,name=algethar_puzzle_box,use_off_gcd=1,if=dot.rupture.ticking&cooldown.deathmark.remains<2|fight_remains<=22 Homebrew: deleted check since its not used anymore
    -- actions.cds+=/use_item,name=ashes_of_the_embersoul,use_off_gcd=1,if=(dot.kingsbane.ticking&dot.kingsbane.remains<=11)|fight_remains<=22
    -- actions.cds+=/use_item,name=witherbarks_branch,use_off_gcd=1,if=(dot.deathmark.ticking)|fight_remains<=22
    -- actions.cds+=/use_items,slots=trinket1,if=(variable.trinket_sync_slot=1&(debuff.deathmark.up|fight_remains<=20)|(variable.trinket_sync_slot=2&(!trinket.2.cooldown.ready|!debuff.deathmark.up&cooldown.deathmark.remains>20))|!variable.trinket_sync_slot)
    -- actions.cds+=/use_items,slots=trinket2,if=(variable.trinket_sync_slot=2&(debuff.deathmark.up|fight_remains<=20)|(variable.trinket_sync_slot=1&(!trinket.1.cooldown.ready|!debuff.deathmark.up&cooldown.deathmark.remains>20))|!variable.trinket_sync_slot)
    if Settings.Commons.UseTrinkets then
      -- Check for Ashes of the Embersoul
      if I.AshesOfTheEmbersoul:IsEquippedAndReady() and
         ((Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) <= 11) or HL.BossFilteredFightRemains("<=", 22)) then
         if HR.Cast(I.AshesOfTheEmbersoul, nil, Settings.Commons.TrinketDisplayStyle) then return "Ashes of the Embersoul"; end
      end
      -- Check for Witherbark's Branch
      if I.WitherBarksBranch:IsEquippedAndReady() and
         (Target:DebuffUp(S.Deathmark) or HL.BossFilteredFightRemains("<=", 22)) then
         if HR.Cast(I.WitherbarksBranch, nil, Settings.Commons.TrinketDisplayStyle) then return "Witherbark's Branch"; end
      end
      if TrinketItem1:IsReady() and not Player:IsItemBlacklisted(TrinketItem1) and not ValueIsInArray(OnUseExcludeTrinkets, TrinketItem1:ID())
        and (TrinketSyncSlot == 1 and (S.Deathmark:AnyDebuffUp() or HL.BossFilteredFightRemains("<", 20))
          or (TrinketSyncSlot == 2 and (not TrinketItem2:IsReady() or not S.Deathmark:AnyDebuffUp() and S.Deathmark:CooldownRemains() > 20)) or TrinketSyncSlot == 0) then
        if Cast(TrinketItem1, nil, Settings.Commons.TrinketDisplayStyle) then return "Trinket 1"; end
      elseif TrinketItem2:IsReady() and not Player:IsItemBlacklisted(TrinketItem2) and not ValueIsInArray(OnUseExcludeTrinkets, TrinketItem2:ID())
        and (TrinketSyncSlot == 2 and (S.Deathmark:AnyDebuffUp() or HL.BossFilteredFightRemains("<", 20))
          or (TrinketSyncSlot == 1 and (not TrinketItem1:IsReady() or not S.Deathmark:AnyDebuffUp() and S.Deathmark:CooldownRemains() > 20)) or TrinketSyncSlot == 0) then
        if Cast(TrinketItem2, nil, Settings.Commons.TrinketDisplayStyle) then return "Trinket 2"; end
      end
    end

    if S.Deathmark:IsCastable() then
      -- actions.cds+=/variable,name=deathmark_ma_condition,value=!talent.master_assassin.enabled|dot.garrote.ticking
      -- actions.cds+=/variable,name=deathmark_kingsbane_condition,value=!talent.kingsbane|(cooldown.kingsbane.remains<=2&buff.envenom.up)
      -- actions.cds+=/variable,name=deathmark_condition,value=!stealthed.rogue&dot.rupture.ticking&buff.envenom.up&!debuff.deathmark.up&variable.deathmark_ma_condition&variable.deathmark_kingsbane_condition
      -- actions.cds+=/deathmark,if=variable.deathmark_condition|fight_remains<=20
      if Target:DebuffUp(S.Rupture) and Player:BuffUp(S.Envenom) and not S.Deathmark:AnyDebuffUp()
        and (not S.MasterAssassin:IsAvailable() or Target:DebuffUp(S.Garrote))
        and (not S.Kingsbane:IsAvailable() or (S.Kingsbane:CooldownRemains() <= 2 and Player:BuffUp(S.Envenom)))
        or HL.BossFilteredFightRemains("<=", 20) then
        if Cast(S.Deathmark, Settings.Assassination.OffGCDasOffGCD.Deathmark) then return "Cast Deathmark" end
      end
    end
  end
  -- actions.cds+=/shiv,if=talent.kingsbane&buff.envenom.up&!debuff.shiv.up&((dot.kingsbane.ticking&dot.kingsbane.remains<8)|cooldown.kingsbane.up|dot.kingsbane.ticking|dot.deathmark.ticking)&dot.garrote.ticking&dot.rupture.ticking&(!talent.crimson_tempest.enabled|variable.single_target|dot.crimson_tempest.ticking)|fight_remains<=charges*8
  if S.Shiv:IsReady() and S.Kingsbane:IsAvailable() and Player:BuffUp(S.Envenom) and not Target:DebuffUp(S.ShivDebuff)
    and ((Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) < 8)
    or S.Kingsbane:CooldownUp() or Target:DebuffUp(S.Kingsbane) or Target:DebuffUp(S.Deathmark))
    and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
    and (not S.CrimsonTempest:IsAvailable() or SingleTarget or Target:DebuffUp(S.CrimsonTempest))
    or HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8) then
    if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Kingsbane)" end
  end

  -- actions.cds+=/shiv,if=talent.kingsbane&buff.envenom.up&!debuff.shiv.up&((dot.kingsbane.ticking&dot.kingsbane.remains<8)|cooldown.kingsbane.remains<=1|dot.kingsbane.ticking|dot.deathmark.ticking)&dot.garrote.ticking&dot.rupture.ticking&(!talent.crimson_tempest.enabled|variable.single_target|dot.crimson_tempest.ticking)|fight_remains<=charges*8
  if S.Shiv:IsReady() and S.Kingsbane:IsAvailable() and Player:BuffUp(S.Envenom) and not Target:DebuffUp(S.ShivDebuff)
    and ((Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) < 8)
    or S.Kingsbane:CooldownRemains() <= 1 or Target:DebuffUp(S.Kingsbane) or Target:DebuffUp(S.Deathmark))
    and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
    and (not S.CrimsonTempest:IsAvailable() or SingleTarget or Target:DebuffUp(S.CrimsonTempest))
    or HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8) then
    if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Kingsbane 1 Second Remaining)" end
  end
  -- actions.cds+=/shiv,if=talent.arterial_precision&!debuff.shiv.up&dot.garrote.ticking&dot.rupture.ticking&debuff.deathmark.up|fight_remains<=charges*8
  if S.Shiv:IsReady() and S.ArterialPrecision:IsAvailable() and not Target:DebuffUp(S.ShivDebuff) and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
    and (Target:DebuffUp(S.Deathmark) or HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8)) then
    if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Arterial Precision)" end
  end

  -- actions.cds+=/shiv,if=talent.sepsis&!talent.kingsbane&!talent.arterial_precision&!debuff.shiv.up&dot.garrote.ticking&dot.rupture.ticking&((cooldown.shiv.charges_fractional>0.9+talent.lightweight_shiv.enabled&variable.sepsis_sync_remains>5)|dot.sepsis.ticking|dot.deathmark.ticking|fight_remains<=charges*8)
  if S.Shiv:IsReady() and S.Sepsis:IsAvailable() and not S.Kingsbane:IsAvailable() and not S.ArterialPrecision:IsAvailable() and not Target:DebuffUp(S.ShivDebuff)
    and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
    and ((S.Shiv:ChargesFractional() > 0.9 + num(S.LightweightShiv:IsAvailable()) and SepsisSyncRemains() > 5) or Target:DebuffUp(S.Sepsis) or Target:DebuffUp(S.Deathmark) 
    or HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8)) then
    if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (Sepsis)" end
  end

  -- actions.cds+=/shiv,if=!talent.kingsbane&!talent.arterial_precision&!talent.sepsis&!debuff.shiv.up&dot.garrote.ticking&dot.rupture.ticking&(!talent.crimson_tempest.enabled|variable.single_target|dot.crimson_tempest.ticking)|fight_remains<=charges*8
  if S.Shiv:IsReady() and not S.Kingsbane:IsAvailable() and not S.ArterialPrecision:IsAvailable() and not S.Sepsis:IsAvailable()
    and not Target:DebuffUp(S.ShivDebuff) and Target:DebuffUp(S.Garrote) and Target:DebuffUp(S.Rupture)
    and ((not S.CrimsonTempest:IsAvailable() or SingleTarget or Target:DebuffUp(S.CrimsonTempest))
    or HL.BossFilteredFightRemains("<=", S.Shiv:Charges() * 8)) then
    if Cast(S.Shiv, Settings.Assassination.GCDasOffGCD.Shiv) then return "Cast Shiv (No-extra)" end
  end
  -- actions.cds+=/shadow_dance,if=talent.kingsbane&cooldown.kingsbane.remains<=1&buff.envenom.up
  if S.ShadowDance:IsReady() and S.Kingsbane:IsAvailable() and S.Kingsbane:CooldownRemains() <= 1 and Player:BuffUp(S.Envenom) then
     if Cast(S.ShadowDance, Settings.Assassination.OffGCDasOffGCD.ShadowDance) then return "Cast Shadow Dance 1" end
  end
  -- actions.cds+=/shadow_dance,if=talent.kingsbane&cooldown.kingsbane.remains<=2&buff.envenom.up
  if S.ShadowDance:IsReady() and S.Kingsbane:IsAvailable() and S.Kingsbane:CooldownRemains() <= 2 and Player:BuffUp(S.Envenom) then
     if Cast(S.ShadowDance, Settings.Assassination.OffGCDasOffGCD.ShadowDance) then return "Cast Shadow Dance 2" end
  end
  -- actions.cds+=/kingsbane,if=(debuff.shiv.up|cooldown.shiv.remains<6)&buff.envenom.up&(cooldown.deathmark.remains>=50|dot.deathmark.ticking)|fight_remains<=15
  if S.Kingsbane:IsReady() and 
   ((Target:DebuffUp(S.ShivDebuff) or S.Shiv:CooldownRemains() < 6) and Player:BuffUp(S.Envenom) 
   and (S.Deathmark:CooldownRemains() >= 50 or Target:DebuffUp(S.Deathmark)) 
   or HL.BossFilteredFightRemains("<=", 15)) then
    if Cast(S.Kingsbane, Settings.Assassination.GCDasOffGCD.Kingsbane) then return "Cast Kingsbane" end
  end
  -- actions.cds+=/thistle_tea,if=!buff.thistle_tea.up&(energy.deficit>=100+energy.regen_combined&(!talent.kingsbane|charges>=2)|(dot.kingsbane.ticking&dot.kingsbane.remains<6|!talent.kingsbane&dot.deathmark.ticking)|fight_remains<charges*6)
  if S.ThistleTea:IsCastable() and not Player:BuffUp(S.ThistleTea)
    and ((Player:EnergyDeficit() >= 100 + EnergyRegenCombined and (not S.Kingsbane:IsAvailable() or S.ThistleTea:Charges() >= 2))
    or ((Target:DebuffUp(S.Kingsbane) and Target:DebuffRemains(S.Kingsbane) < 6)
    or (not S.Kingsbane:IsAvailable() and Target:DebuffUp(S.Deathmark)))
    or HL.BossFilteredFightRemains("<", S.ThistleTea:Charges() * 6)) then
    if HR.Cast(S.ThistleTea, Settings.Commons.OffGCDasOffGCD.ThistleTea) then return "Cast Thistle Tea" end
  end

  if not HR.CDsON() then
    return
  end

  -- actions.cds=potion,if=buff.bloodlust.react|target.time_to_die<=60|debuff.vendetta.up&cooldown.vanish.remains<5
  -- Racials
  if S.Deathmark:AnyDebuffUp() and (not ShouldReturn or Settings.Commons.OffGCDasOffGCD.Racials) then
    if ShouldReturn then
      Racials()
    else
      ShouldReturn = Racials()
    end
  end

  -- actions.cds+=/call_action_list,name=vanish,if=!stealthed.all&master_assassin_remains=0
  if not Player:StealthUp(true, true) and ImprovedGarroteRemains() <= 0 and MasterAssassinRemains() <= 0 then
    if ShouldReturn then
      Vanish()
    else
      ShouldReturn = Vanish()
    end
  end
  -- actions.cds+=/cold_blood,if=combo_points>=4
  if S.ColdBlood:IsReady() and Player:DebuffDown(S.ColdBlood) and ComboPoints >= 4 
    and (Settings.Commons.OffGCDasOffGCD.ColdBlood or not ShouldReturn) then
    if Cast(S.ColdBlood, Settings.Commons.OffGCDasOffGCD.ColdBlood) then return "Cast Cold Blood" end
  end

  return ShouldReturn
end

-- # Stealthed
local function Stealthed ()
  -- actions.stealthed+=/shiv,if=talent.kingsbane&(dot.kingsbane.ticking|cooldown.kingsbane.up)&(!debuff.shiv.up&debuff.shiv.remains<1)&buff.envenom.up
  if S.Shiv:IsCastable() and S.Kingsbane:IsAvailable() and
    (Target:DebuffUp(S.Kingsbane) or S.Kingsbane:CooldownUp()) and
    (not Target:DebuffUp(S.ShivDebuff) or Target:DebuffRemains(S.ShivDebuff) < 1) and
    Player:BuffUp(S.Envenom) then
    if Cast(S.Shiv) then return "Cast Shiv (Stealth)" end
  end
  -- actions.stealthed+=/kingsbane,if=buff.shadow_dance.remains>=2&buff.envenom.up
  if S.Kingsbane:IsCastable() and Player:BuffRemains(S.ShadowDanceBuff) >= 2 and Player:BuffUp(S.Envenom) then
    if Cast(S.Kingsbane) then return "Cast Kingsbane (Stealth)" end
  end
  -- actions.stealthed+=/envenom,if=effective_combo_points>=4&dot.kingsbane.ticking&buff.envenom.remains<=3
  if S.Envenom:IsReady() and ComboPoints >= 4 and Target:DebuffUp(S.Kingsbane) and Player:BuffRemains(S.Envenom) <= 3 then
    if Cast(S.Envenom) then return "Cast Envenom (Stealth)" end
  end
  -- actions.stealthed+=/envenom,if=effective_combo_points>=4&buff.master_assassin_aura.up&!buff.shadow_dance.up&variable.single_target
  if S.Envenom:IsReady() and ComboPoints >= 4 and Player:BuffUp(S.MasterAssassin) and not Player:BuffUp(S.ShadowDance) and SingleTarget then
    if Cast(S.Envenom) then return "Cast Envenom (Master Assassin)" end
  end

  if S.Garrote:IsCastable() and (ImprovedGarroteRemains() > 0) then
    -- actions.stealthed+=/garrote,target_if=min:remains,if=stealthed.improved_garrote&(remains<(12-buff.sepsis_buff.remains)|pmultiplier<=1|(buff.indiscriminate_carnage.up&active_dot.garrote<spell_targets.fan_of_knives))&(!variable.single_target|!dot.deathmark.ticking&combo_points.deficit>=3|dot.deathmark.ticking&combo_points.deficit>=4)&target.time_to_die-remains>2
    local function GarroteTargetIfFunc(TargetUnit)
      return TargetUnit:DebuffRemains(S.Garrote)
    end
    local function GarroteIfFunc(TargetUnit)
        return ((TargetUnit:DebuffRemains(S.Garrote) < (12 - Player:BuffRemains(S.SepsisBuff))) or (TargetUnit:PMultiplier(S.Garrote) <= 1)
        or (Player:BuffUp(S.IndiscriminateCarnage) and TargetUnit:DebuffRemains(S.Garrote) < MeleeEnemies10yCount))
        and (not SingleTarget or ((not TargetUnit:DebuffUp(S.Deathmark) and ComboPointsDeficit >= 3)
        or (TargetUnit:DebuffUp(S.Deathmark) and Player:ComboPointsDeficit() >= 4)))
        and TargetUnit:FilteredTimeToDie(">", 2, -TargetUnit:DebuffRemains(S.Garrote))
    end
    if HR.AoEON() then
      local TargetIfUnit = CheckTargetIfTarget("min", GarroteTargetIfFunc, GarroteIfFunc)
      if TargetIfUnit and TargetIfUnit:GUID() ~= Target:GUID() then
        CastLeftNameplate(TargetIfUnit, S.Garrote)
      end
    end
    if GarroteIfFunc(Target) then
      -- actions.stealthed+=/garrote,target_if=min:remains,if=stealthed.improved_garrote&(remains<(12-buff.sepsis_buff.remains)|pmultiplier<=1|(buff.indiscriminate_carnage.up&active_dot.garrote<spell_targets.fan_of_knives))&(!variable.single_target|!dot.deathmark.ticking&combo_points.deficit>=3|dot.deathmark.ticking&combo_points.deficit>=4)&target.time_to_die-remains>2
      if CastPooling(S.Garrote, nil, not TargetInMeleeRange) then return "Cast Garrote (Improved Garrote) 1" end
    end
    -- actions.stealthed+=/garrote,if=stealthed.improved_garrote&!buff.shadow_dance.up&(pmultiplier<=1|dot.deathmark.ticking&buff.master_assassin_aura.remains<3)&combo_points.deficit>=5
    if not Player:BuffUp(S.ShadowDance) and (Target:PMultiplier(S.Garrote) <= 1 or (Target:DebuffUp(S.Deathmark) and Player:BuffRemains(S.MasterAssassin) < 3)) and ComboPointsDeficit >= 5 then
      if CastPooling(S.Garrote, nil, not TargetInMeleeRange) then return "Cast Garrote (Improved Garrote) 2" end
    end
    -- garrote,if=stealthed.improved_garrote&(pmultiplier<=1|dot.deathmark.ticking)&combo_points.deficit>=5
    if (Target:PMultiplier(S.Garrote) or Target:DebuffUp(S.Deathmark)) and ComboPointsDeficit >= 5 then
      if CastPooling(S.Garrote, nil, not TargetInMeleeRange) then return "Cast Garrote (Improved Garrote) 3" end
    end
  end
  -- actions.stealthed+=/rupture,if=effective_combo_points>=4&(pmultiplier<=1)&(buff.shadow_dance.up|debuff.deathmark.up)
  if S.Rupture:IsReady() and ComboPoints >= 4 and (Target:PMultiplier(S.Rupture) <= 1) and (Player:BuffUp(S.ShadowDanceBuff) or Target:DebuffUp(S.Deathmark)) then
     if Cast(S.Rupture) then return "Cast Rupture (Stealth)" end
  end
end


-- # Damage over time abilities
local function Dot ()
  -- actions.dot=variable,name=scent_effective_max_stacks,value=(spell_targets.fan_of_knives*talent.scent_of_blood.rank*2)>?20
  local scent_effective_max_stacks = math.min(MeleeEnemies10yCount * S.ScentofBlood:TalentRank() * 2, 20)
  -- actions.dot+=/variable,name=scent_saturation,value=buff.scent_of_blood.stack>=variable.scent_effective_max_stacks
  local scent_saturation = Player:BuffStack(S.ScentofBloodBuff) >= scent_effective_max_stacks

  -- actions.dot+=/crimson_tempest,target_if=min:remains,if=spell_targets>=2&refreshable&effective_combo_points>=4&energy.regen_combined>25&!cooldown.deathmark.ready&target.time_to_die-remains>6
  if HR.AoEON() and S.CrimsonTempest:IsReady() and MeleeEnemies10yCount >= 2 and ComboPoints >= 4
     and EnergyRegenCombined > 25 and not S.Deathmark:CooldownUp() then
     for _, CycleUnit in pairs(MeleeEnemies10y) do
        if CycleUnit:DebuffRefreshable(S.CrimsonTempest) and CycleUnit:TimeToDie() - CycleUnit:DebuffRemains(S.CrimsonTempest) > 6 then
          if Cast(S.CrimsonTempest) then return "Cast Crimson Tempest (AoE)" end
        end
     end
  end
  -- rupture,if=(effective_combo_points>=3+!variable.single_target|effective_combo_points*4+4+dot.rupture.remains>cooldown.shadow_dance.remains+4+6.1&effective_combo_points*4+4+dot.rupture.remains<=cooldown.shadow_dance.remains+4+6.1+4)&(pmultiplier<=1|dot.rupture.remains<5.1)&refreshable&dot.rupture.remains<cooldown.shadow_dance.remains+2&target.time_to_die-remains>(4+(talent.dashing_scoundrel*5)+(variable.regen_saturated*6))
  if S.Rupture:IsReady() then
     if (ComboPoints >= 3 + num(not SingleTarget) or ComboPoints * 4 + 4 + Target:DebuffRemains(S.Rupture) > S.ShadowDance:CooldownRemains() + 4 + 6.1
      and ComboPoints * 4 + 4 + Target:DebuffRemains(S.Rupture) <= S.ShadowDance:CooldownRemains() + 4 + 6.1 + 4)
      and (Target:PMultiplier(S.Rupture) <= 1 or Target:DebuffRemains(S.Rupture) < 5.1)
      and IsDebuffRefreshable(Target, S.Rupture) and Target:DebuffRemains(S.Rupture) < S.ShadowDance:CooldownRemains() + 2
      and Target:FilteredTimeToDie(">", 4 + BoolToInt(S.DashingScoundrel:IsAvailable()) * 5 + BoolToInt(EnergyRegenSaturated) * 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid() then
      if Cast(S.Rupture, nil, nil, not TargetInMeleeRange) then return "Cast Rupture (Refresh)" end
     end
  end
  -- actions.dot+=/garrote,if=combo_points.deficit>=1&(pmultiplier<=1)&refreshable&target.time_to_die-remains>12&cooldown.shadow_dance.remains+1>dot.garrote.remains
  if S.Garrote:IsCastable() and TargetInMeleeRange and ComboPointsDeficit >= 1
      and (Target:PMultiplier(S.Garrote) <= 1) and IsDebuffRefreshable(Target, S.Garrote)
      and Target:FilteredTimeToDie(">", 12, -Target:DebuffRemains(S.Garrote))
      and (S.ShadowDance:CooldownRemains() + 1 > Target:DebuffRemains(S.Garrote)) then
      if CastPooling(S.Garrote) then return "Cast Garrote 1" end
  end
  -- actions.dot+=/garrote,cycle_targets=1,if=combo_points.deficit>=1&(pmultiplier<=1)&refreshable&!variable.regen_saturated&spell_targets.fan_of_knives>=2&target.time_to_die-remains>12 TODO: Get this to work
  -- actions.dot+=/garrote,if=refreshable&combo_points.deficit>=1&(pmultiplier<=1|remains<=tick_time&spell_targets.fan_of_knives>=3)&(remains<=tick_time*2&spell_targets.fan_of_knives>=3)&(target.time_to_die-remains)>4&master_assassin_remains=0
  -- refreshable&combo_points.deficit>=1&(pmultiplier<=1|remains<=tick_time&spell_targets.fan_of_knives>=3)&(remains<=tick_time*2&spell_targets.fan_of_knives>=3)&(target.time_to_die-remains)>4&master_assassin_remains=0 -- TODO: get this to work
  if S.Garrote:IsCastable() and ComboPointsDeficit >= 1 then
      local function Evaluate_Garrote_Target(TargetUnit)
      GarroteTickTime = BleedTickTime
      return IsDebuffRefreshable(Target, S.Garrote) and MasterAssassinRemains() <= 0
      and (TargetUnit:PMultiplier(S.Garrote) <= 1 or (MeleeEnemies10yCount >= 3 and TargetUnit:DebuffRemains(S.Garrote) <= GarroteTickTime))
      and TargetUnit:DebuffRemains(S.Garrote) <= GarroteTickTime * (1 + BoolToInt(MeleeEnemies10yCount >= 3))
  end
    if Evaluate_Garrote_Target(Target) and Rogue.CanDoTUnit(Target, GarroteDMGThreshold)
      and (Target:FilteredTimeToDie(">", 4, -Target:DebuffRemains(S.Garrote)) or Target:TimeToDieIsNotValid()) then
      -- actions.dot+=/pool_resource,for_next=1
      if CastPooling(S.Garrote, nil, not TargetInMeleeRange) then return "Pool for Garrote (ST)" end
    end
    if HR.AoEON() and not SkipCycleGarrote then
      SuggestCycleDoT(S.Garrote, Evaluate_Garrote_Target, 12, MeleeEnemies5y)
    end
  end

  return false
end

-- # Direct damage abilities
local function Direct ()
  -- actions.direct=envenom,if=effective_combo_points>=4&(variable.not_pooling|debuff.amplifying_poison.stack>=20|effective_combo_points>cp_max_spend|!variable.single_target)
  if S.Envenom:IsReady() and ComboPoints >= 4 
    and (not_pooling() or Target:DebuffStack(S.AmplifyingPoisonDebuff) >= 20 or ComboPoints > Rogue.CPMaxSpend() or not SingleTarget) then
    if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom" end
  end

  --- !!!! ---
  -- actions.direct+=/variable,name=use_filler,value=combo_points.deficit>1|variable.not_pooling|!variable.single_target
  -- Note: This is used in all following fillers, so we just return false if not true and won't consider these.
  if not (ComboPointsDeficit > 1 or not_pooling() or not SingleTarget) then
    return false
  end
  --- !!!! ---

  -- actions.direct+=/mutilate,if=talent.caustic_spatter&dot.rupture.ticking&(!debuff.caustic_spatter.up|debuff.caustic_spatter.remains<=2)&variable.use_filler&!variable.single_target
  if S.Mutilate:IsReady() and S.CausticSpatter:IsAvailable() and Target:DebuffUp(S.Rupture) 
     and (not Target:DebuffUp(S.CausticSpatterDebuff) or Target:DebuffRemains(S.CausticSpatterDebuff) <= 2)
     and not SingleTarget then
     if Cast(S.Mutilate, nil, nil, not TargetInMeleeRange) then return "Cast Mutilate CS" end
  end


  if S.SerratedBoneSpike:IsReady() then
    -- actions.direct+=/serrated_bone_spike,if=variable.use_filler&!dot.serrated_bone_spike_dot.ticking
    if not Target:DebuffUp(S.SerratedBoneSpikeDebuff) then
      if Cast(S.SerratedBoneSpike, nil, Settings.Commons.CovenantDisplayStyle, not TargetInAoERange) then return "Cast Serrated Bone Spike" end
    else
      -- actions.direct+=/serrated_bone_spike,target_if=min:target.time_to_die+(dot.serrated_bone_spike_dot.ticking*600),if=variable.use_filler&!dot.serrated_bone_spike_dot.ticking
      if HR.AoEON() then
        if Everyone.CastTargetIf(S.SerratedBoneSpike, Enemies30y, "min", EvaluateSBSTargetIfConditionCondition, EvaluateSBSCondition) then
          return "Cast Serrated Bone (AoE)"
        end
      end
      -- actions.direct+=/serrated_bone_spike,if=variable.use_filler&master_assassin_remains<0.8&(fight_remains<=5|cooldown.serrated_bone_spike.max_charges-charges_fractional<=0.25)
      -- actions.direct+=/serrated_bone_spike,if=variable.use_filler&master_assassin_remains<0.8&!variable.single_target&debuff.shiv.up
      if MasterAssassinRemains() < 0.8 then
        if (HL.BossFightRemains() <= 5 or (S.SerratedBoneSpike:MaxCharges() - S.SerratedBoneSpike:ChargesFractional() <= 0.25)) then
          if Cast(S.SerratedBoneSpike, nil, Settings.Commons.SerratedBoneSpikeDumpDisplayStyle, not TargetInAoERange) then return "Cast Serrated Bone Spike (Dump Charge)" end
        elseif not SingleTarget and Target:DebuffUp(S.ShivDebuff) then
          if Cast(S.SerratedBoneSpike, nil, Settings.Commons.SerratedBoneSpikeDumpDisplayStyle, not TargetInAoERange) then return "Cast Serrated Bone Spike (Shiv)" end
        end
      end
    end
  end
  -- actions.direct+=/echoing_reprimand,if=variable.use_filler|fight_remains<20 Homebrew Check for ER.
  if (CDsON() and S.EchoingReprimand:IsReady() and S.EchoingReprimand:IsAvailable()) or (HL.BossFilteredFightRemains("<=", 20) and S.EchoingReprimand:IsAvailable() and S.EchoingReprimand:IsReady()) then
    if Cast(S.EchoingReprimand, nil, Settings.Commons.CovenantDisplayStyle, not TargetInMeleeRange) then return "Cast Echoing Reprimand" end
  end
  if S.FanofKnives:IsCastable() then
    -- actions.direct+=/fan_of_knives,if=variable.use_filler&(!priority_rotation&spell_targets.fan_of_knives>=2+stealthed.rogue+talent.dragontempered_blades)
    if HR.AoEON() and MeleeEnemies10yCount >= 1 and (not PriorityRotation
      and MeleeEnemies10yCount >= 2 + BoolToInt(Player:StealthUp(true, false)) + BoolToInt(S.DragonTemperedBlades:IsAvailable())) then
      if CastPooling(S.FanofKnives) then return "Cast Fan of Knives" end
    end
    -- actions.direct+=/fan_of_knives,target_if=!dot.deadly_poison_dot.ticking&(!priority_rotation|dot.garrote.ticking|dot.rupture.ticking),if=variable.use_filler&spell_targets.fan_of_knives>=3
    if HR.AoEON() and Player:BuffUp(S.DeadlyPoison) and MeleeEnemies10yCount >= 3 then
      for _, CycleUnit in pairs(MeleeEnemies10y) do
        if not CycleUnit:DebuffUp(S.DeadlyPoisonDebuff, true) and (not PriorityRotation or CycleUnit:DebuffUp(S.Garrote) or CycleUnit:DebuffUp(S.Rupture)) then
          if CastPooling(S.FanofKnives) then return "Cast Fan of Knives (DP Refresh)" end
        end
      end
    end
  end
  -- actions.direct+=/ambush,if=variable.use_filler&(buff.blindside.up|buff.sepsis_buff.remains<=1|stealthed.rogue)&(!dot.kingsbane.ticking|debuff.deathmark.down|buff.blindside.up)
  if S.Ambush:IsReady() and (Player:BuffUp(S.BlindsideBuff) or Player:BuffRemains(S.SepsisBuff) <= 1 or Player:StealthUp(true, false))
     and (not Target:DebuffUp(S.Kingsbane) or not Target:DebuffUp(S.Deathmark) or Player:BuffUp(S.BlindsideBuff)) then
     if CastPooling(S.Ambush, nil, not TargetInMeleeRange) then return "Cast Ambush" end
  end
  -- actions.direct+=/mutilate,target_if=!dot.deadly_poison_dot.ticking&!debuff.amplifying_poison.up,if=variable.use_filler&spell_targets.fan_of_knives=2
  if S.Mutilate:IsCastable() and MeleeEnemies10yCount == 2 and Target:DebuffDown(S.DeadlyPoisonDebuff, true)
    and Target:DebuffDown(S.AmplifyingPoisonDebuff, true) then
    local TargetGUID = Target:GUID()
    for _, CycleUnit in pairs(MeleeEnemies5y) do
      -- Note: The APL does not do this due to target_if mechanics, but since we are cycling we should check to see if the unit has a bleed
      if CycleUnit:GUID() ~= TargetGUID and (CycleUnit:DebuffUp(S.Garrote) or CycleUnit:DebuffUp(S.Rupture))
        and not CycleUnit:DebuffUp(S.DeadlyPoisonDebuff, true) and not CycleUnit:DebuffUp(S.AmplifyingPoisonDebuff, true) then
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
  MeleeRange = S.AcrobaticStrikes:IsAvailable() and 8 or 5
  AoERange = S.AcrobaticStrikes:IsAvailable() and 10 or 13
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
  ComboPointsDeficit = Player:ComboPointsMax() - ComboPoints
  RuptureThreshold = (4 + ComboPoints * 4) * 0.3
  CrimsonTempestThreshold = (2 + ComboPoints * 2) * 0.3
  RuptureDMGThreshold = S.Envenom:Damage() * Settings.Assassination.EnvenomDMGOffset; -- Used to check if Rupture is worth to be casted since it's a finisher.
  GarroteDMGThreshold = S.Mutilate:Damage() * Settings.Assassination.MutilateDMGOffset; -- Used as TTD Not Valid fallback since it's a generator.
  PriorityRotation = UsePriorityRotation()

  -- Defensives
  -- Crimson Vial
  ShouldReturn = Rogue.CrimsonVial()
  if ShouldReturn then return ShouldReturn end
  -- Feint
  ShouldReturn = Rogue.Feint()
  if ShouldReturn then return ShouldReturn end

  -- Poisons
  Rogue.Poisons()

  -- Out of Combat
  if not Player:AffectingCombat() then
    -- actions=stealth
    if not Player:BuffUp(Rogue.VanishBuffSpell()) then
      ShouldReturn = Rogue.Stealth(Rogue.StealthSpell())
      if ShouldReturn then return ShouldReturn end
    end
    -- Flask
    -- Food
    -- Rune
    -- PrePot w/ Bossmod Countdown
    -- Opener
    if Everyone.TargetIsValid() then
      -- Precombat CDs
      -- actions.precombat+=/slice_and_dice,precombat_seconds=1
      if not Player:BuffUp(S.SliceandDice) then
        if S.SliceandDice:IsReady() and ComboPoints >= 2 then
          if Cast(S.SliceandDice) then return "Cast Slice and Dice (OOC)" end
        end
      end
    end
  end

  -- In Combat
  if Everyone.TargetIsValid() then
    -- Interrupts
    ShouldReturn = Everyone.Interrupt(5, S.Kick, Settings.Commons2.OffGCDasOffGCD.Kick, Interrupts)
    if ShouldReturn then return ShouldReturn end
  
    PoisonedBleeds = Rogue.PoisonedBleeds()
    -- TODO: Make this match the updated code version
    EnergyRegenCombined = Player:EnergyRegen() + PoisonedBleeds * 6 / (2 * Player:SpellHaste())
    EnergyTimeToMaxCombined = Player:EnergyDeficit() / EnergyRegenCombined
    -- actions+=/variable,name=regen_saturated,value=energy.regen_combined>35
    EnergyRegenSaturated = EnergyRegenCombined > 35
    -- actions+=/variable,name=single_target,value=spell_targets.fan_of_knives<2
    SingleTarget = MeleeEnemies10yCount < 2

    -- actions+=/call_action_list,name=stealthed,if=stealthed.rogue|stealthed.improved_garrote|buff.master_assassin_aura.up|buff.master_assassin.up|buff.subterfuge.up
    if Player:StealthUp(true, false) or ImprovedGarroteRemains() > 0 or Player:BuffUp(S.MasterAssassin) or Player:BuffUp(S.MasterAssassinBuff) or Player:BuffUp(S.Subterfuge) then
      ShouldReturn = Stealthed()
      if ShouldReturn then return ShouldReturn .. " (Stealthed)" end
    end
    -- actions+=/call_action_list,name=cds
    ShouldReturn = CDs()
    if ShouldReturn then return ShouldReturn end
    -- # Put SnD up initially for Cut to the Chase, refresh with Envenom if at low duration
    -- actions+=/slice_and_dice,if=!buff.slice_and_dice.up&combo_points>=2|!talent.cut_to_the_chase&refreshable&combo_points>=4
    if not Player:BuffUp(S.SliceandDice) then
      if S.SliceandDice:IsReady() and Player:ComboPoints() >= 2
        or not S.CutToTheChase:IsAvailable() and Player:ComboPoints() >= 4 and Player:BuffRemains(S.SliceandDice) < (1 + Player:ComboPoints()) * 1.8 then
        if Cast(S.SliceandDice) then return "Cast Slice and Dice" end
      end
    elseif TargetInAoERange and S.CutToTheChase:IsAvailable() then
      -- actions+=/envenom,if=talent.cut_to_the_chase&buff.slice_and_dice.up&buff.slice_and_dice.remains<5&combo_points>=4
      if S.Envenom:IsReady() and Player:BuffRemains(S.SliceandDice) < 5 and Player:ComboPoints() >= 4 then
        if Cast(S.Envenom, nil, nil, not TargetInMeleeRange) then return "Cast Envenom (CttC)" end
      end
    else
      --- !!!! ---
      -- Special fallback Poisoned Knife Out of Range [EnergyCap] or [PoisonRefresh]
      -- Only if we are about to cap energy, not stealthed, and completely out of range
      --- !!!! ---
      if S.PoisonedKnife:IsCastable() and Target:IsInRange(30) and not Player:StealthUp(true, true)
        and MeleeEnemies10yCount == 0 and Player:EnergyTimeToMax() <= Player:GCD() * 1.5 then
        if Cast(S.PoisonedKnife) then return "Cast Poisoned Knife" end
      end
    end
    -- actions+=/call_action_list,name=dot
    ShouldReturn = Dot()
    if ShouldReturn then return ShouldReturn end
    -- actions+=/call_action_list,name=direct
    ShouldReturn = Direct()
    if ShouldReturn then return ShouldReturn end
    -- Racials
    if HR.CDsON() then
      -- actions+=/arcane_torrent,if=energy.deficit>=15+variable.energy_regen_combined
      if S.ArcaneTorrent:IsCastable() and TargetInMeleeRange and Player:EnergyDeficit() > 15 then
        if Cast(S.ArcaneTorrent, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Arcane Torrent" end
      end
      -- actions+=/arcane_pulse
      if S.ArcanePulse:IsCastable() and TargetInMeleeRange then
        if Cast(S.ArcanePulse, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Arcane Pulse" end
      end
      -- actions+=/lights_judgment
      if S.LightsJudgment:IsCastable() and TargetInMeleeRange then
        if Cast(S.LightsJudgment, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Lights Judgment" end
      end
      -- actions+=/bag_of_tricks
      if S.BagofTricks:IsCastable() and TargetInMeleeRange then
        if Cast(S.BagofTricks, Settings.Commons.GCDasOffGCD.Racials) then return "Cast Bag of Tricks" end
      end
    end
    -- Trick to take in consideration the Recovery Setting
    if S.Mutilate:IsCastable() or S.Ambush:IsCastable() and TargetInAoERange then
      if Cast(S.PoolEnergy) then return "Normal Pooling" end
    end
  end
end

local function Init ()
  S.Deathmark:RegisterAuraTracking()
  S.Sepsis:RegisterAuraTracking()
end

HR.SetAPL(259, APL, Init)

--- ======= SIMC =======
-- Last Update: 2023-11-03


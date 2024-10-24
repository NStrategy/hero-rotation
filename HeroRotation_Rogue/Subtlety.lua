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
-- WoW API
local Delay = C_Timer.After
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
  I.BottledFlayedwingToxin:ID(),
  I.ImperfectAscendancySerum:ID(),
  I.MadQueensMandate:ID(),
  I.SkardynsGrace:ID()
}
-- Rotation Var
local MeleeRange, AoERange, TargetInMeleeRange, TargetInAoERange
local Enemies30y, MeleeEnemies10y, MeleeEnemies10yCount, MeleeEnemies5y
local ShouldReturn; -- Used to get the return string
local PoolingAbility, PoolingEnergy, PoolingFinisher; -- Used to store an ability we might want to pool for as a fallback in the current situation
local RuptureThreshold, RuptureDMGThreshold
local EffectiveComboPoints, ComboPoints, ComboPointsDeficit
local PriorityRotation
local DungeonSlice
local InRaid

-- Trinkets
local trinket1, trinket2
local VarTrinketFailures = 0
local function SetTrinketVariables()
  local T1, T2 = Player:GetTrinketData(OnUseExcludes)

  -- If we don't have trinket items, try again in 5 seconds.
  if VarTrinketFailures < 5 and ((T1.ID == 0 or T2.ID == 0) or (T1.SpellID > 0 and not T1.Usable or T2.SpellID > 0 and not T2.Usable)) then
    VarTrinketFailures = VarTrinketFailures + 1
    Delay(5, function()
      SetTrinketVariables()
    end
    )
    return
  end

  trinket1 = T1.Object
  trinket2 = T2.Object
end
SetTrinketVariables()

HL:RegisterForEvent(function()
  SetTrinketVariables()
end, "PLAYER_EQUIPMENT_CHANGED")

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
    -- NW Zolramus Necromancer
    elseif Target:NPCID() == 163618 then
      return true
    -- NW Surgeon Stitchflesh
    elseif Target:NPCID() == 166882 then
      return true
    -- GB Faceless Corruptor
    elseif Target:NPCID() == 48844 then
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
-- Define a table with NPC IDs that should be skipped:
-- Ravenous Spawn (216205), Blood Horror (221986), Infested Spawn (439815), Blood Parasite (220626), Caustic Skitterer (223674), Gloom Hatchling (221344),
-- Battle Scarab (220199), Congealed Droplet (216329), Umbral Weave (222700) or/and (220065), Hungry Scarab (222974), Ravenous Scarab (219198),
-- Ravenous Crawler (216336) or/and (219221), Jabbing Flyer (216341), Swarming Flyer (218325), Starved Crawler (218961), Bloodworker (216337) or (215826),
-- Black Blood (215968) or/and (216856), Crystal Shard (214443), Earth Burst Totem (214287),
-- Spinemaw Larva (167117), Gormling Larva (165560), Carrion Worm (164702), Brittlebone Warrior (163122) or/and (168445), Brittlebone Mage (163126),
-- Brittlebone Crossbowman (166079), Shuffling Corpse (171500), Spare Parts (166266), Invoked Shadowflame Spirit (40357), Mutated Hatchling (224853) or/and (39388)
-- Scrimshaw Gutter (133990), Irontide Curseblade (138247), Irontide Powdershot (138254)
local NPCIDTable = {
  [216205] = true, [221986] = true, [439815] = true, [220626] = true, [223674] = true, [221344] = true,
  [220199] = true, [216329] = true, [222700] = true, [220065] = true, [222974] = true, [219198] = true,
  [216336] = true, [219221] = true, [216341] = true, [218325] = true, [218961] = true, [216337] = true,
  [215826] = true, [215968] = true, [216856] = true, [214443] = true, [214287] = true,
  [167117] = true, [165560] = true, [164702] = true, [163122] = true, [168445] = true, [163126] = true,
  [166079] = true, [171500] = true, [166266] = true,  [40357] = true, [224853] = true,  [39388] = true,
  [133990] = true, [138247] = true, [138254] = true
}
local function Skip_Rupture_NPC(Unit) -- Exclude Rupture Dot for certain NPCs
  local NPCID = Unit:NPCID()
  return NPCIDTable[NPCID] or false -- Check if the NPC ID is in the table
end
local function Stealth ()
  -- actions+=/variable,name=stealth,value=buff.shadow_dance.up|buff.stealth.up|buff.vanish.up
  return Player:BuffUp(S.ShadowDanceBuff) or Player:BuffUp(S.Stealth) or Player:BuffUp(S.Stealth2) or Player:BuffUp(S.VanishBuff) or Player:BuffUp(S.VanishBuff2)
end
local function Skip_Rupture (ShadowDanceBuff)
  -- actions+=/variable,name=skip_rupture,value=buff.shadow_dance.up|!buff.slice_and_dice.up|buff.darkest_night.up|variable.targets>=8&!talent.replicating_shadows&talent.unseen_blade
  return Player:BuffUp(S.ShadowDanceBuff) or not Player:BuffUp(S.SliceandDice) or Player:BuffUp(S.DarkestNightBuff) or MeleeEnemies10yCount >= 8 and not S.ReplicatingShadows:IsAvailable() and S.UnseenBlade:IsAvailable()
end
local function Maintenance()
  -- actions+=/variable,name=maintenance,value=(dot.rupture.ticking|variable.skip_rupture)&buff.slice_and_dice.up
  return (Target:DebuffUp(S.Rupture) or Skip_Rupture() or Skip_Rupture_NPC(Target)) and Player:BuffUp(S.SliceandDice)
end
local function Secret()
  -- actions+=/variable,name=secret,value=buff.shadow_dance.up|(cooldown.flagellation.remains<40&cooldown.flagellation.remains>20&talent.death_perception)
  return Player:BuffUp(S.ShadowDanceBuff) or (S.Flagellation:CooldownRemains() < 40 and S.Flagellation:CooldownRemains() > 20 and S.DeathPerception:IsAvailable())
end
local function ShdCP()
  -- actions+=/variable,name=shd_cp,value=combo_points<=1|buff.shadow_techniques.stack>=7|buff.darkest_night.up&combo_points>=7|effective_combo_points>=6&talent.unseen_blade
  return ComboPoints <= 1 or Player:BuffStack(S.ShadowTechniques) >= 7 or Player:BuffUp(S.DarkestNightBuff) and ComboPoints >= 7 or EffectiveComboPoints >= 6 and S.UnseenBlade:IsAvailable()
end

local function Used_For_Danse(Spell)
  return Player:BuffUp(S.ShadowDanceBuff) and Spell:TimeSinceLastCast() < S.ShadowDance:TimeSinceLastCast()
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
  -- actions.precombat+=/variable,name=trinket_sync_slot,value=1,if=trinket.1.is.treacherous_transmitter
  if trinket1:ID() == I.TreacherousTransmitter:ID() then
    TrinketSyncSlot = 1
  end
  return TrinketSyncSlot
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
  end

  -- actions.finish=secret_technique,if=variable.secret
  -- Attention: Due to the SecTec/ColdBlood interaction, this adaption has additional checks not found in the APL string 
  if S.SecretTechnique:IsCastable() and Secret() then
    if ReturnSpellOnly then 
      return S.SecretTechnique
    else
      if S.SecretTechnique:IsCastable() and HR.Cast(S.SecretTechnique) then return "Cast Secret Technique" end
      SetPoolingFinisher(S.SecretTechnique)
    end
  end
  -- # Maintenance Finisher
  local SkipRupture = Skip_Rupture(ShadowDanceBuff)
  -- actions.finish+=/rupture,if=!variable.skip_rupture&(!dot.rupture.ticking|refreshable)&target.time_to_die-remains>6
  if S.Rupture:IsCastable() and (not Player:BuffUp(S.ShadowDanceBuff) and not SkipRupture and not Skip_Rupture_NPC(Target)) then
    if (not Target:DebuffUp(S.Rupture) or Target:DebuffRefreshable(S.Rupture, RuptureThreshold)) and (Target:FilteredTimeToDie(">", 6, -Target:DebuffRemains(S.Rupture)) or Target:TimeToDieIsNotValid()) then
      if ReturnSpellOnly then
        return S.Rupture
      else
        if S.Rupture:IsCastable() and HR.Cast(S.Rupture) then return "Cast Rupture" end
        SetPoolingFinisher(S.Rupture)
      end
    end
  end
  if not ShadowDanceBuff and not SkipRupture and S.Rupture:IsCastable() then
    -- actions.finish+=/rupture,cycle_targets=1,if=!variable.skip_rupture&!variable.priority_rotation&target.time_to_die>=(2*combo_points)&refreshable&variable.targets>=2
    if not ReturnSpellOnly and HR.AoEON() and not PriorityRotation and MeleeEnemies10yCount >= 2 then
      local function Evaluate_Rupture_Target(TargetUnit)
        return not Skip_Rupture_NPC(TargetUnit)
          and Everyone.CanDoTUnit(TargetUnit, RuptureDMGThreshold)
          and TargetUnit:DebuffRefreshable(S.Rupture, RuptureThreshold)
      end
      SuggestCycleDoT(S.Rupture, Evaluate_Rupture_Target, (2 * FinishComboPoints), MeleeEnemies5y)
    end
  end
  -- # Direct Damage Finisher
  -- # BlackPowder
  -- actions.finish+=/black_powder,if=!variable.priority_rotation&variable.maintenance&variable.targets>=2&!buff.flawless_form.up&!buff.darkest_night.up
  if S.BlackPowder:IsCastable() and not PriorityRotation and Maintenance() and MeleeEnemies10yCount >= 2 and not Player:BuffUp(S.FlawlessFormBuff) and not Player:BuffUp(S.DarkestNightBuff) then
    if ReturnSpellOnly then
      return S.BlackPowder
    else
      if S.BlackPowder:IsCastable() and HR.Cast(S.BlackPowder) then return "Cast Black Powder" end
      SetPoolingFinisher(S.BlackPowder)
    end
  end
  -- actions.finish+=/coup_de_grace,if=debuff.fazed.up
  if S.CoupDeGrace:IsCastable() and TargetInMeleeRange and Target:DebuffUp(S.FazedDebuff) then
    if ReturnSpellOnly then
      return S.CoupDeGrace
    else
      if S.CoupDeGrace:IsCastable() and HR.Cast(S.CoupDeGrace) then return "Cast Coup De Grace" end
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
  end

  local StealthEffectiveComboPoints = Rogue.EffectiveComboPoints(StealthComboPoints)
  local ShadowstrikeIsCastable = S.Shadowstrike:IsCastable() or StealthBuff or VanishBuffCheck or ShadowDanceBuff or Player:BuffUp(S.SepsisBuff)
  if StealthBuff or VanishBuffCheck then
    ShadowstrikeIsCastable = ShadowstrikeIsCastable and Target:IsInRange(25)
  else
    ShadowstrikeIsCastable = ShadowstrikeIsCastable and TargetInMeleeRange
  end

  -- actions+=/call_action_list,name=finish,if=!buff.darkest_night.up&effective_combo_points>=6|buff.darkest_night.up&combo_points==cp_max_spend note: from 6 to 5 as finishing on 5 inside of dance is fine.
  if (not Player:BuffUp(S.DarkestNightBuff) and StealthEffectiveComboPoints >= 5) or (Player:BuffUp(S.DarkestNightBuff) and StealthComboPoints == Rogue.CPMaxSpend()) then
    return Finish(ReturnSpellOnly, StealthSpell)
  end
  -- # Use shadowstrike for Danse Macabre on aoe and for Trickster use it instead of storm on 2+ targets
  -- actions.stealthed+=/shadowstrike,if=(!used_for_danse&buff.shadow_blades.up)|(talent.unseen_blade&spell_targets>=2)
  if ShadowstrikeIsCastable and Target:DebuffRemains(S.FindWeaknessDebuff) <= 2 and MeleeEnemies10yCount >= 2 and S.UnseenBlade:IsAvailable() or (not Used_For_Danse(S.Shadowstrike) and S.DanseMacabre:IsAvailable()) then
      if ReturnSpellOnly then
          return S.Shadowstrike
      else
          if HR.Cast(S.Shadowstrike) then return "Cast Shadowstrike" end
      end
  end
  if S.ShurikenTornado:IsCastable() then
    if Player:BuffUp(S.LingeringDarknessBuff) or S.DeathStalkersMark:IsAvailable() and S.ShadowBlades:CooldownRemains() >= 32 and MeleeEnemies10yCount >= 2 or S.UnseenBlade:IsAvailable() and Player:BuffUp(S.SymbolsofDeath) and MeleeEnemies10yCount >= 4 then
      if ReturnSpellOnly then
        return S.ShurikenTornado
      else
        if HR.Cast(S.ShurikenTornado) then return "Cast Shuriken Tornado" end
      end
    end
  end 
      -- actions.build+=/shuriken_storm,if=talent.deathstalkers_mark&!buff.premeditation.up&variable.targets>=(2+3*buff.shadow_dance.up)|buff.clear_the_witnesses.up&!buff.symbols_of_death.up|buff.flawless_form.up&variable.targets>=3&!variable.stealth
  if HR.AoEON() and S.ShurikenStorm:IsCastable() then
    if S.DeathStalkersMark:IsAvailable() and not Player:BuffUp(S.PremeditationBuff) and MeleeEnemies10yCount >= (2 + 3 * BoolToInt(Player:BuffUp(S.ShadowDanceBuff))) or Player:BuffUp(S.ClearTheWitnessesBuff) and not Player:BuffUp(S.SymbolsofDeath) or Player:BuffUp(S.FlawlessFormBuff) and MeleeEnemies10yCount >= 3 and not Stealth() then
      if ReturnSpellOnly then
        return S.ShurikenStorm
      else
        if HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
      end
    end
  end
  -- actions.build+=/goremaws_bite,if=combo_points.deficit>=3
  if S.GoremawsBite:IsCastable() and ComboPointsDeficit >= 3 then
    if ReturnSpellOnly then
      return S.GoremawsBite
    else
      if HR.Cast(S.GoremawsBite) then return "Cast GoremawsBite" end
    end
  end
  -- actions.stealthed+=/gloomblade,if=buff.lingering_shadow.remains>=10&buff.shadow_blades.up&spell_targets=1
  if S.Gloomblade:IsCastable() then
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
  if HR.CDsON() then
    -- actions.cds+=/cold_blood,if=cooldown.secret_technique.up&buff.shadow_dance.up&combo_points>=6&variable.secret
    if S.ColdBlood:IsCastable() and S.SecretTechnique:CooldownUp() and Player:BuffUp(S.ShadowDanceBuff) 
      and ComboPoints >= 6 and Secret() then
      if HR.Cast(S.ColdBlood, Settings.CommonsOGCD.OffGCDasOffGCD.ColdBlood, EnergyThreshold) then return "Cast Cold Blood" end
    end
    -- actions.cds+=/potion,if=buff.bloodlust.react|fight_remains<30|buff.flagellation_buff.up
    if Settings.Commons.Enabled.Potions then
      local PotionSelected = Everyone.PotionSelected()
      if PotionSelected and PotionSelected:IsReady() and (Player:BloodlustUp() or (HL.BossFilteredFightRemains("<", 30) and InRaid) or Player:BuffUp(S.FlagellationBuff)) then
        if Cast(PotionSelected, nil, Settings.CommonsDS.DisplayStyle.Potions, EnergyThreshold) then return "Cast Potion"; end
      end
    end
    -- actions.cds+=/symbols_of_death,if=(buff.symbols_of_death.remains<=3&variable.maintenance&(buff.flagellation_buff.up|!talent.flagellation|cooldown.flagellation.remains>=30-15*!talent.death_perception&cooldown.secret_technique.remains<=8|!talent.death_perception)|fight_remains<=15)
    if S.SymbolsofDeath:IsCastable() and (Player:BuffRemains(S.SymbolsofDeath) <= 3 and Maintenance() and (Player:BuffUp(S.FlagellationBuff) or not S.Flagellation:IsAvailable() or S.Flagellation:CooldownRemains() >= 30 - (not S.DeathPerception:IsAvailable() and 15 or 0) and S.SecretTechnique:CooldownRemains() <= 8 or not S.DeathPerception:IsAvailable()) or (HL.BossFilteredFightRemains("<=", 15) and InRaid)) then
      if HR.Cast(S.SymbolsofDeath, Settings.Subtlety.OffGCDasOffGCD.SymbolsofDeath, EnergyThreshold) then return "Cast Symbols of Death No Dust" end
    end
    -- actions.cds+=/shadow_blades,if=variable.maintenance&variable.shd_cp&buff.shadow_dance.up&!buff.premeditation.up
    if S.ShadowBlades:IsCastable() then
      if Maintenance() and ShdCP() and Player:BuffUp(S.ShadowDanceBuff) and not Player:BuffUp(S.Premeditation) then 
        if HR.Cast(S.ShadowBlades, Settings.Subtlety.OffGCDasOffGCD.ShadowBlades, EnergyThreshold) then return "Cast Shadow Blades" end
      end
    end
    -- actions.cds+=/thistle_tea,if=buff.shadow_dance.remains>2&!buff.thistle_tea.up
    if S.ThistleTea:IsCastable() and not Player:BuffUp(S.ThistleTea) and Player:BuffRemains(S.ShadowDanceBuff) > 2 then
      if HR.Cast(S.ThistleTea, Settings.CommonsOGCD.OffGCDasOffGCD.ThistleTea, EnergyThreshold) then return "Cast Thistle Tea" end
    end
    -- actions.cds+=/flagellation,if=combo_points>=5|fight_remains<=25
    if S.Flagellation:IsCastable() and ComboPoints >= 5 or (HL.BossFilteredFightRemains("<=", 25) and InRaid) then
      if HR.Cast(S.Flagellation, Settings.Subtlety.OffGCDasOffGCD.Flagellation, EnergyThreshold) then return "Cast Flagellation" end
    end
    -- CUSTOM CONDITIONS
    
    -- # Race Cooldowns
    -- actions+=/variable,name=racial_sync,value=(buff.flagellation_buff.up&buff.shadow_dance.up)|!talent.shadow_blades&buff.symbols_of_death.up|fight_remains<20
    if (Player:BuffUp(S.FlagellationBuff) and Player:BuffUp(S.ShadowDanceBuff)) or not S.ShadowBlades:IsAvailable() and Player:BuffUp(S.SymbolsofDeath) or (HL.BossFilteredFightRemains("<", 20) and InRaid) then
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

-- # Trinket and Items
local function Items()
  if Settings.Commons.Enabled.Trinkets then
    -- actions.item=use_item,name=treacherous_transmitter,if=cooldown.flagellation.remains<=2|fight_remains<=15
    if I.TreacherousTransmitter:IsEquippedAndReady() then
      if S.Flagellation:CooldownRemains() <= 2 or (HL.BossFilteredFightRemains("<=", 15) and InRaid) then
        if Cast(I.TreacherousTransmitter, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Treacherous Transmitter" end
      end
    end
    --actions.item+=/use_item,name=imperfect_ascendancy_serum,use_off_gcd=1,if=dot.rupture.ticking&buff.flagellation_buff.up
    if I.ImperfectAscendancySerum:IsEquippedAndReady() then
      if (Target:DebuffUp(S.Rupture) or Skip_Rupture_NPC(Target)) and Player:BuffUp(S.Flagellation) then
        if Cast(I.ImperfectAscendancySerum, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Imperfect Ascendancy Serum" end
      end
    end
    -- actions.item+=/use_item,name=mad_queens_mandate,if=(!talent.lingering_darkness|buff.lingering_darkness.up|equipped.treacherous_transmitter)&(!equipped.treacherous_transmitter|trinket.treacherous_transmitter.cooldown.remains>20)|fight_remains<=15
    if I.MadQueensMandate:IsEquippedAndReady() then
      if (not S.LingeringDarkness:IsAvailable() or Player:BuffUp(S.LingeringDarknessBuff) or I.TreacherousTransmitter:IsEquipped()) and (not I.TreacherousTransmitter:IsEquipped() or I.TreacherousTransmitter:CooldownRemains() > 20) or (HL.BossFilteredFightRemains("<=", 15) and InRaid) then
        if Cast(I.MadQueensMandate, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then return "Mad Queen's Mandate" end
      end
    end
    -- Reset Check 
    if I.MadQueensMandate:IsEquippedAndReady() then
      local calculatedDamage = CalculateMadQueensDamage()
      -- Only cast the trinket if the calculated damage exceeds the target's current health
      if calculatedDamage >= Target:Health() then
          if Cast(I.MadQueensMandate, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
              return "Mad Queen's Mandate";
          end
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
      if not ValueIsInArray(OnUseExcludes, trinket1:ID()) and (Trinket_Sync_Slot() == 1 and (Player:BuffUp(S.ShadowBlades) or (1 + S.ShadowBlades:CooldownRemains()) >= trinket1:CooldownRemains()) or (Trinket_Sync_Slot() == 2 and (not trinket2:IsReady() and not Player:BuffUp(S.ShadowBlades) and S.ShadowBlades:CooldownRemains() > 20)) or Trinket_Sync_Slot() == 0) then
          if Cast(trinket1, nil, Settings.CommonsDS.DisplayStyle.Trinkets, not Target:IsInRange(TrinketRange)) then return "Generic use_items for " .. trinket1:Name() end
      end
    end

    --actions.items+=/use_items,slots=trinket2,if=(variable.trinket_sync_slot=2&(buff.shadow_blades.up|(1+cooldown.shadow_blades.remains)>=trinket.2.cooldown.duration|fight_remains<=20)|(variable.trinket_sync_slot=1&(!trinket.1.cooldown.ready&!buff.shadow_blades.up&cooldown.shadow_blades.remains>20))|!variable.trinket_sync_slot)
    if trinket2 then
      TrinketSpell = trinket2:OnUseSpell()
      TrinketRange = (TrinketSpell and TrinketSpell.MaximumRange > 0 and TrinketSpell.MaximumRange <= 100) and TrinketSpell.MaximumRange or 100
    end
    if trinket2:IsEquippedAndReady() then
      if not ValueIsInArray(OnUseExcludes, trinket2:ID()) and (Trinket_Sync_Slot() == 2 and (Player:BuffUp(S.ShadowBlades) or (1 + S.ShadowBlades:CooldownRemains()) >= trinket2:CooldownRemains()) or (Trinket_Sync_Slot() == 1 and (not trinket1:IsReady() and not Player:BuffUp(S.ShadowBlades) and S.ShadowBlades:CooldownRemains() > 20)) or Trinket_Sync_Slot() == 0) then
          if Cast(trinket2, nil, Settings.CommonsDS.DisplayStyle.Trinkets, not Target:IsInRange(TrinketRange)) then return "Generic use_items for " .. trinket2:Name() end
      end
    end
  end

  return false
end
-- # Shadow Dance, Vanish, Shadowmeld
local function Stealth_CDs (EnergyThreshold)
  if HR.CDsON() then
    if TargetInMeleeRange and S.ShadowDance:IsCastable() and HR.CDsON() then
      -- actions.stealth_cds=shadow_dance,if=variable.shd_cp&variable.maintenance&cooldown.secret_technique.remains<=24&(buff.symbols_of_death.remains>=6|buff.flagellation_persist.remains>=6)|fight_remains<=10
      if ShdCP() and Maintenance() and S.SecretTechnique:CooldownRemains() <= 24 and (Player:BuffRemains(S.SymbolsofDeath) >= 6 or Player:BuffRemains(S.FlagellationPersistBuff) >= 6) or (HL.BossFilteredFightRemains("<=", 10) and InRaid) then
          ShouldReturn = StealthMacro(S.ShadowDance, EnergyThreshold)
          if ShouldReturn then return "ShadowDance Macro " .. ShouldReturn end
      end
    end
    -- actions.stealth_cds+=/vanish,if=energy>=40&combo_points.deficit>=3
    if S.Vanish:IsCastable() and Player:EnergyDeficitPredicted() < 40 and ComboPointsDeficit >= 3 then
      ShouldReturn = StealthMacro(S.Vanish, EnergyThreshold)
      if ShouldReturn then return "Vanish Macro " .. ShouldReturn end
    end
    -- actions.stealth_cds+=/shadowmeld,if=energy>=40&combo_points.deficit>3
    if S.Shadowmeld:IsCastable() and TargetInMeleeRange and not Player:IsMoving() and ComboPointsDeficit > 3 then
      -- actions.stealth_cds+=/pool_resource,for_next=1,extra_amount=40, if=race.night_elf
      if Player:EnergyDeficitPredicted() < 40 then
        if HR.CastPooling(S.Shadowmeld, Player:EnergyTimeToX(40)) then return "Pool for Shadowmeld" end
      end
      ShouldReturn = StealthMacro(S.Shadowmeld, EnergyThreshold)
      if ShouldReturn then return "Shadowmeld Macro " .. ShouldReturn end
    end
  end

  return false
end

-- # Builders
local function Build (EnergyThreshold)
  local ThresholdMet = not EnergyThreshold or Player:EnergyPredicted() >= EnergyThreshold
  -- actions.build+=/shuriken_storm,if=talent.deathstalkers_mark&!buff.premeditation.up&variable.targets>=(2+3*buff.shadow_dance.up)|buff.clear_the_witnesses.up&!buff.symbols_of_death.up|buff.flawless_form.up&variable.targets>=3&!variable.stealth
  if HR.AoEON() and S.ShurikenStorm:IsCastable() then
    if S.DeathStalkersMark:IsAvailable() and not Player:BuffUp(S.PremeditationBuff) and MeleeEnemies10yCount >= (2 + 3 * BoolToInt(Player:BuffUp(S.ShadowDanceBuff))) or Player:BuffUp(S.ClearTheWitnessesBuff) and not Player:BuffUp(S.SymbolsofDeath) or Player:BuffUp(S.FlawlessFormBuff) and MeleeEnemies10yCount >= 3 and not Stealth() then
      if ThresholdMet and HR.Cast(S.ShurikenStorm) then return "Cast Shuriken Storm" end
      SetPoolingAbility(S.ShurikenStorm, EnergyThreshold)
    end
  end
  -- actions.build+=/shuriken_tornado,if=buff.lingering_darkness.up|talent.deathstalkers_mark&cooldown.shadow_blades.remains>=32&variable.targets>=2|talent.unseen_blade&buff.symbols_of_death.up&variable.targets>=4
  if S.ShurikenTornado:IsCastable() then
    if Player:BuffUp(S.LingeringDarknessBuff) or S.DeathStalkersMark:IsAvailable() and S.ShadowBlades:CooldownRemains() >= 32 and MeleeEnemies10yCount >= 2 or S.UnseenBlade:IsAvailable() and Player:BuffUp(S.SymbolsofDeath) and MeleeEnemies10yCount >= 4 then
      if ThresholdMet and HR.Cast(S.ShurikenTornado) then return "Cast Shuriken Tornado" end
      SetPoolingAbility(S.ShurikenTornado, EnergyThreshold)
    end
  end
  if TargetInMeleeRange then
    -- actions.build+=/goremaws_bite,if=combo_points.deficit>=3
    if S.GoremawsBite:IsCastable() and ComboPointsDeficit >= 3 then
      if ThresholdMet and Cast(S.GoremawsBite, nil, nil, not Target:IsSpellInRange(S.GoremawsBite)) then return "Cast GoremawsBite" end
      SetPoolingAbility(S.GoremawsBite, EnergyThreshold)
    end
    -- actions.build+=/gloomblade
    if S.Gloomblade:IsCastable() then
      if ThresholdMet and Cast(S.Gloomblade, nil, nil, not Target:IsSpellInRange(S.Gloomblade)) then return "Cast Gloomblade" end
      SetPoolingAbility(S.Gloomblade, EnergyThreshold)
    -- actions.build+=/backstab
    elseif S.Backstab:IsCastable() then
      if ThresholdMet and Cast(S.Backstab, nil, nil, not Target:IsSpellInRange(S.Backstab)) then return "Cast Backstab" end
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
  DungeonSlice = Player:IsInParty() and Player:IsInDungeonArea()
  InRaid = Player:IsInRaid()

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

  -- Bottled Flayedwing Toxin
  if I.BottledFlayedwingToxin:IsEquippedAndReady() and Player:BuffDown(S.FlayedwingToxin) then
    if Cast(I.BottledFlayedwingToxin, nil, Settings.CommonsDS.DisplayStyle.Trinkets) then
      return "Bottle Of Flayedwing Toxin";
    end
  end
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
    if Everyone.TargetIsValid() and Target:IsSpellInRange(S.Shadowstrike) then
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
        if Cast(S.Backstab, nil, nil, not Target:IsSpellInRange(S.Backstab)) then return "Cast Backstab (OOC)" end
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
            and (PoolingAbility == S.SecretTechnique or PoolingAbility == S.BlackPowder or PoolingAbility == S.Eviscerate ) then
            if HR.CastQueuePooling(nil, S.ShurikenTornado, PoolingAbility) then return "Stealthed Tornado Cast  " .. PoolingAbility:Name() end
          else  
            if CastPooling(PoolingAbility, nil, not Target:IsSpellInRange(PoolingAbility)) then return "Stealthed Cast " .. PoolingAbility:Name() end
          end
        end
      end
      HR.Cast(S.PoolEnergy)
      return "Stealthed Pooling"
    end

    -- # Check if you should use dance, vanish or shadowmeld to enter stealth
    -- actions+=/call_action_list,name=stealth_cds
    if not Stealth() then
      ShouldReturn = Stealth_CDs()
      if ShouldReturn then return "Stealth CDs: " .. ShouldReturn end
    end

    -- actions+=/call_action_list,name=finish,if=!buff.darkest_night.up&effective_combo_points>=6|buff.darkest_night.up&combo_points==cp_max_spend
    if (not Player:BuffUp(S.DarkestNightBuff) and EffectiveComboPoints >= 6) or (Player:BuffUp(S.DarkestNightBuff) and ComboPoints == Rogue.CPMaxSpend()) then
      ShouldReturn = Finish()
      if ShouldReturn then return "Finish: " .. ShouldReturn end
    else
      -- # Use a builder when reaching the energy threshold
      -- actions+=/call_action_list,name=build,if=energy.deficit<=variable.stealth_threshold
      ShouldReturn = Build()
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

  HR.Print("You are using a fork [Version 2.3]: THIS IS NOT THE OFFICIAL VERSION - if there are issues, message me on Discord: kekwxqcl")
end

HR.SetAPL(261, APL, Init)

-- Last Update 2023-12-02
-- Using Fuus lasted posted APL in the TC-Subtlety, too lazy to copy :)

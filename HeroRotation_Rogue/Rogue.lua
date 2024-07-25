--- ============================ HEADER ============================
--- ======= LOCALIZE =======
-- Addon
local addonName, addonTable = ...
-- HeroDBC
local DBC = HeroDBC.DBC
-- HeroLib
local HL         = HeroLib
local Cache      = HeroCache
local Unit       = HL.Unit
local Player     = Unit.Player
local Target     = Unit.Target
local MouseOver  = Unit.MouseOver
local Spell      = HL.Spell
local MultiSpell = HL.MultiSpell
local Item       = HL.Item
local MergeTableByKey = HL.Utils.MergeTableByKey
-- HeroRotation
local HR = HeroRotation
local Everyone = HR.Commons.Everyone
-- Lua
local mathmin = math.min
local pairs = pairs
-- File Locals
local Commons = {}

--- ======= GLOBALIZE =======
HR.Commons.Rogue = Commons

--- ============================ CONTENT ============================
-- GUI Settings
local Settings = {
  General = HR.GUISettings.General,
  Commons = HR.GUISettings.APL.Rogue.Commons,
  CommonsDS = HR.GUISettings.APL.Rogue.CommonsDS,
  CommonsOGCD = HR.GUISettings.APL.Rogue.CommonsOGCD,
  Assassination = HR.GUISettings.APL.Rogue.Assassination,
  Outlaw = HR.GUISettings.APL.Rogue.Outlaw,
  Subtlety = HR.GUISettings.APL.Rogue.Subtlety
}

-- Spells
if not Spell.Rogue then Spell.Rogue = {} end

Spell.Rogue.Commons = {
  -- Racials
  AncestralCall           = Spell(274738),
  ArcanePulse             = Spell(260364),
  ArcaneTorrent           = Spell(25046),
  BagofTricks             = Spell(312411),
  Berserking              = Spell(26297),
  BloodFury               = Spell(20572),
  Fireblood               = Spell(265221),
  LightsJudgment          = Spell(255647),
  Shadowmeld              = Spell(58984),
  -- Defensive
  CloakofShadows          = Spell(31224),
  CrimsonVial             = Spell(185311),
  Evasion                 = Spell(5277),
  Feint                   = Spell(1966),
  -- Utility
  Blind                   = Spell(2094),
  CheapShot               = Spell(1833),
  Kick                    = Spell(1766),
  KidneyShot              = Spell(408),
  PickPocket              = Spell(921),
  Sap                     = Spell(6770),
  Shiv                    = Spell(5938),
  SliceandDice            = Spell(315496),
  Shadowstep              = Spell(36554),
  Sprint                  = Spell(2983),
  TricksoftheTrade        = Spell(57934),
  -- Talents
  Alacrity                = Spell(193539),
  ColdBlood               = Spell(382245),
  DeeperStratagem         = Spell(193531),
  EchoingReprimand        = Spell(385616),
  EchoingReprimand2       = Spell(323558),
  EchoingReprimand3       = Spell(323559),
  EchoingReprimand4       = Spell(323560),
  EchoingReprimand5       = Spell(354838),
  FindWeakness            = Spell(91023),
  FindWeaknessDebuff      = Spell(316220),
  ImprovedAmbush          = Spell(381620),
  MarkedforDeath          = Spell(137619),
  Nightstalker            = Spell(14062), -- bringing back Nightstalker as PMMultipler causes issues
  ResoundingClarity       = Spell(381622),
  Reverberation           = Spell(394332),
  SealFate                = Spell(14190),
  Subterfuge              = Spell(108208),
  SubterfugeBuff          = Spell(115192),
  ShadowDance             = Spell(185313), -- keeping this here till offical version fixes Aura.lua
  ShadowDanceBuff         = Spell(185422),
  ThistleTea              = Spell(381623),
  Vigor                   = Spell(14983),
  WithoutATrace           = Spell(382513),
  -- Hero Talents
  DarkestNight            = Spell(457058),
  DarkestNightBuff        = Spell(457280),
  DeathStalkersMark       = Spell(457052),
  DeathStalkersMarkBuff   = Spell(457157),
  DoubleJeopardy          = Spell(454430),
  TakeEmBySurprise        = Spell(382742),
  TakeEmBySurpriseBuff    = Spell(385907),
  HandofFate              = Spell(452536),
  FlawlessForm            = Spell(441321),
  FlawlessFormBuff        = Spell(441326),
  UnseenBlade             = Spell(441146),
  UnseenBladeBuff         = Spell(459485),
  -- Stealth
  Stealth                 = Spell(1784),
  Stealth2                = Spell(115191),
  Vanish                  = Spell(1856),
  VanishBuff              = Spell(11327),
  VanishBuff2             = Spell(115193),
  -- Trinkets
  -- Misc
  PoolEnergy              = Spell(999910),
}

Spell.Rogue.Assassination = MergeTableByKey(Spell.Rogue.Commons, {
  -- Abilities
  Ambush                  = Spell(8676),
  AmbushOverride          = Spell(430023),
  AmplifyingPoison        = Spell(381664),
  AmplifyingPoisonDebuff  = Spell(383414),
  AmplifyingPoisonDebuffDeathmark = Spell(394328),
  CripplingPoisonDebuff   = Spell(3409),
  DeadlyPoison            = Spell(2823),
  DeadlyPoisonDebuff      = Spell(2818),
  DeadlyPoisonDebuffDeathmark = Spell(394324),
  Envenom                 = Spell(32645),
  FanofKnives             = Spell(51723),
  Garrote                 = Spell(703),
  GarroteDeathmark        = Spell(360830),
  Mutilate                = Spell(1329),
  PoisonedKnife           = Spell(185565),
  Rupture                 = Spell(1943),
  RuptureDeathmark        = Spell(360826),
  WoundPoison             = Spell(8679),
  WoundPoisonDebuff       = Spell(8680),
  -- Talents
  ArterialPrecision       = Spell(400783),
  AtrophicPoisonDebuff    = Spell(392388),
  BlindsideBuff           = Spell(121153),
  CausticSpatter          = Spell(421975),
  CausticSpatterDebuff    = Spell(421976),
  CrimsonTempest          = Spell(121411),
  CutToTheChase           = Spell(51667),
  DashingScoundrel        = Spell(381797),
  Deathmark               = Spell(360194),
  Doomblade               = Spell(381673),
  DragonTemperedBlades    = Spell(381801),
  Elusiveness             = Spell(79008),
  ImprovedGarrote         = Spell(381632),
  ImprovedGarroteBuff     = Spell(392401),
  ImprovedGarroteAura     = Spell(392403),
  IndiscriminateCarnage   = Spell(381802),
  IndiscriminateCarnageAura = Spell(385754),
  IndiscriminateCarnageBuff = Spell(385747),
  InternalBleeding        = Spell(154953),
  Kingsbane               = Spell(385627),
  LightweightShiv         = Spell(394983),
  MasterAssassin          = Spell(255989),
  MasterAssassinBuff      = Spell(256735),
  PreyontheWeak           = Spell(131511),
  PreyontheWeakDebuff     = Spell(255909),
  ScentOfBlood            = Spell(381799),
  ScentOfBloodBuff        = Spell(394080),
  SerratedBoneSpike       = Spell(385424),
  SerratedBoneSpikeDebuff = Spell(394036),
  ShivDebuff              = Spell(319504),
  ShroudedSuffocation     = Spell(385478),
  VenomRush               = Spell(152152),
  ZoldyckRecipe           = Spell(381798),
  -- PvP
})

Spell.Rogue.Outlaw = MergeTableByKey(Spell.Rogue.Commons, {
  -- Abilities
  AdrenalineRush          = Spell(13750),
  Ambush                  = Spell(8676),
  SSAudacity              = Spell(197834),
  AmbushOverride          = Spell(430023),
  BetweentheEyes          = Spell(315341),
  BladeFlurry             = Spell(13877),
  Dispatch                = Spell(2098),
  Elusiveness             = Spell(79008),
  Opportunity             = Spell(195627),
  PistolShot              = Spell(185763),
  RolltheBones            = Spell(315508),
  SinisterStrike          = Spell(193315),
  -- Talents
  Audacity                = Spell(381845),
  AudacityBuff            = Spell(386270),
  BladeRush               = Spell(271877),
  CountTheOdds            = Spell(381982),
  Crackshot               = Spell(423703),
  DeftManeuvers           = Spell(381878),
  Dreadblades             = Spell(343142),
  FanTheHammer            = Spell(381846),
  GhostlyStrike           = Spell(196937),
  GreenskinsWickers       = Spell(386823),
  GreenskinsWickersBuff   = Spell(394131),
  HiddenOpportunity       = Spell(383281),
  ImprovedAdrenalineRush  = Spell(395422),
  ImprovedBetweenTheEyes  = Spell(235484),
  KeepItRolling           = Spell(381989),
  KillingSpree            = Spell(51690),
  LoadedDiceBuff          = Spell(256171),
  PreyontheWeak           = Spell(131511),
  PreyontheWeakDebuff     = Spell(255909),
  QuickDraw               = Spell(196938),
  Ruthlessness            = Spell(14161),
  SummarilyDispatched     = Spell(381990),
  SwiftSlasher            = Spell(381988),
  UnderhandedUpperhand    = Spell(424044),
  Weaponmaster            = Spell(200733),
  -- Utility
  Gouge                   = Spell(1776),
  -- PvP
  -- Roll the Bones
  Broadside               = Spell(193356),
  BuriedTreasure          = Spell(199600),
  GrandMelee              = Spell(193358),
  RuthlessPrecision       = Spell(193357),
  SkullandCrossbones      = Spell(199603),
  TrueBearing             = Spell(193359),
  -- Set Bonuses
  ViciousFollowup         = Spell(394879),
})

Spell.Rogue.Subtlety = MergeTableByKey(Spell.Rogue.Commons, {
  -- Abilities
  Backstab                = Spell(53),
  BlackPowder             = Spell(319175),
  Elusiveness             = Spell(79008),
  Eviscerate              = Spell(196819),
  Rupture                 = Spell(1943),
  ShadowBlades            = Spell(121471),
  Shadowstrike            = Spell(185438),
  ShurikenStorm           = Spell(197835),
  ShadowTechniques        = Spell(196911),  
  ShurikenToss            = Spell(114014),
  SymbolsofDeath          = Spell(212283),
  -- Talents
  CloakedinShadows        = Spell(382515),
  CloakedinShadowsBuff    = Spell(386165),
  DanseMacabre            = Spell(382528),
  DanseMacabreBuff        = Spell(393969),
  DeeperDaggers           = Spell(382517),
  DeeperDaggersBuff       = Spell(383405),
  DarkBrew                = Spell(382504),
  DarkShadow              = Spell(245687),
  DoubleDance             = Spell(394930),
  EnvelopingShadows       = Spell(238104),
  Finality                = Spell(382525),
  FinalityBlackPowderBuff = Spell(385948),
  FinalityEviscerateBuff  = Spell(385949),
  FinalityRuptureBuff     = Spell(385951),
  Flagellation            = Spell(384631),
  FlagellationPersistBuff = Spell(394758),
  Gloomblade              = Spell(200758),
  GoremawsBite            = Spell(426591),
  ImprovedShadowDance     = Spell(393972),
  ImprovedShurikenStorm   = Spell(319951),
  InvigoratingShadowdust  = Spell(382523),
  LingeringShadow         = Spell(382524),
  LingeringShadowBuff     = Spell(385960),
  MasterofShadows         = Spell(196976),
  PerforatedVeins         = Spell(382518),
  PerforatedVeinsBuff     = Spell(394254),
  PreyontheWeak           = Spell(131511),
  PreyontheWeakDebuff     = Spell(255909),
  Premeditation           = Spell(343160),
  PremeditationBuff       = Spell(343173),
  SecretStratagem         = Spell(394320),
  SecretTechnique         = Spell(280719),
  Sepsis                  = Spell(385408),
  SepsisBuff              = Spell(375939),
  Shadowcraft             = Spell(426594),
  ShadowFocus             = Spell(108209),
  ShurikenTornado         = Spell(277925),
  SilentStorm             = Spell(385722),
  SilentStormBuff         = Spell(385727),
  SwiftDeath              = Spell(394309),
  TheFirstDance           = Spell(382505),
  TheRotten               = Spell(382015),
  TheRottenBuff           = Spell(394203),
  Weaponmaster            = Spell(193537),
  -- PvP
  -- Set Bonuses
  ShadowRupture           = Spell(424493),
})

-- Items
if not Item.Rogue then Item.Rogue = {} end
Item.Rogue.Assassination = {
  -- Trinkets
  AlgetharPuzzleBox       = Item(193701, {13, 14}),
  MirrorOfFracturedTomorrows = Item(207581, {13, 14}),
  AshesoftheEmbersoul        = Item(207167, {13, 14}),
  IrideusFragment            = Item(193743, {13, 14}),
  WitherbarksBranch          = Item(109999, {13, 14}),
}

Item.Rogue.Outlaw = {
  -- Trinkets
  ManicGrieftorch         = Item(194308, {13, 14}),
  WindscarWhetstone       = Item(137486, {13, 14}),
  BeaconToTheBeyond       = Item(203963, {13, 14}),
  DragonfireBombDispenser = Item(202610, {13, 14}),
  BattleReadyGoggles      = Item(198326,{1}),
  PersonalSpaceAmplifier  = Item(255940,{6}), -- If you are playing with this enchant, please put your belt item id here instead of "255940". Only then you will not get suggestions.
}

Item.Rogue.Subtlety = {
  -- Trinkets
  ManicGrieftorch            = Item(194308, {13, 14}),
  StormEatersBoon            = Item(194302, {13, 14}),
  BeaconToTheBeyond          = Item(203963, {13, 14}),
  MirrorOfFracturedTomorrows = Item(207581, {13, 14}),
  AshesoftheEmbersoul        = Item(207167, {13, 14}),
  IrideusFragment            = Item(193743, {13, 14}),
  ImperfectAscendancySerum   = Item(225654, {13, 14}),
  WitherbarksBranch          = Item(109999, {13, 14}),
  BandolierOfTwistedBlades   = Item(207165, {13, 14}),
  BattleReadyGoggles         = Item(198326,{1}),
  PersonalSpaceAmplifier     = Item(255940,{6}) -- If you are playing with this enchant, please put your belt item id here instead of "255940". Only then you will not get suggestions.
}

function Commons.StealthSpell()
  return Spell.Rogue.Commons.Subterfuge:IsAvailable() and Spell.Rogue.Commons.Stealth2 or Spell.Rogue.Commons.Stealth
end

function Commons.VanishBuffSpell()
  return Spell.Rogue.Commons.Subterfuge:IsAvailable() and Spell.Rogue.Commons.VanishBuff2 or Spell.Rogue.Commons.VanishBuff
end

-- Stealth
function Commons.Stealth(Stealth, Setting)
  if (Settings.Commons.ShowStealthOOC or Everyone.TargetIsValid()) and Stealth:IsCastable() and Player:StealthDown() then
    if HR.Cast(Stealth, nil, Settings.CommonsDS.DisplayStyle.Stealth) then return "Cast Stealth (OOC)" end
  end

  return false
end

-- Crimson Vial
do
  local CrimsonVial = Spell(185311)

  function Commons.CrimsonVial()
    if CrimsonVial:IsCastable() and Player:HealthPercentage() <= Settings.Commons.CrimsonVialHP then
      if HR.Cast(CrimsonVial, Settings.CommonsOGCD.GCDasOffGCD.CrimsonVial) then return "Cast Crimson Vial (Defensives)" end
    end

    return false
  end
end

-- Poisons
do
  local CripplingPoison     = Spell(3408)
  local DeadlyPoison        = Spell(2823)
  local InstantPoison       = Spell(315584)
  local AmplifyingPoison    = Spell(381664)
  local NumbingPoison       = Spell(5761)
  local WoundPoison         = Spell(8679)
  local AtrophicPoison      = Spell(381637)

  local PoisonRemains = 0
  local UsingWoundPoison = false

  local function CastPoison(Poison)
    PoisonRemains = Player:BuffRemains(Poison)
    if PoisonRemains < (Player:AffectingCombat() and 120 or 300) then
      HR.CastSuggested(Poison)
    end
  end

  function Commons.Poisons()
    if Settings.Commons.ShowPoisonOOC or Everyone.TargetIsValid() or Player:AffectingCombat() then
      local PoisonRefreshTime = Player:AffectingCombat() and 120 or 300
      local PoisonRemains
      -- Lethal Poison
      UsingWoundPoison = Player:BuffUp(WoundPoison)

      if Spell.Rogue.Assassination.DragonTemperedBlades:IsAvailable() then
        CastPoison(UsingWoundPoison and WoundPoison or DeadlyPoison)
        if AmplifyingPoison:IsAvailable() then
          CastPoison(AmplifyingPoison)
        else
          CastPoison(InstantPoison)
        end
      else
        if UsingWoundPoison then
          CastPoison(WoundPoison)
        elseif AmplifyingPoison:IsAvailable() and Player:BuffDown(DeadlyPoison) then
          CastPoison(AmplifyingPoison)
        elseif DeadlyPoison:IsAvailable() then
          CastPoison(DeadlyPoison)
        else
          CastPoison(InstantPoison)
        end
      end

      -- Non-Lethal Poisons
      if Player:BuffDown(CripplingPoison) then
        if AtrophicPoison:IsAvailable() then
          CastPoison(AtrophicPoison)
        elseif NumbingPoison:IsAvailable() then
          CastPoison(NumbingPoison)
        else
          CastPoison(CripplingPoison)
        end
      else
        CastPoison(CripplingPoison)
      end
    end
  end
end

-- Everyone CanDotUnit override, originally used for Mantle legendary
-- Is it worth to DoT the unit ?
function Commons.CanDoTUnit(ThisUnit, HealthThreshold)
  return Everyone.CanDoTUnit(ThisUnit, HealthThreshold)
end

-- PMultipliers


--- ======= SIMC CUSTOM FUNCTION / EXPRESSION =======
-- cp_max_spend
do
  local DeeperStratagem = Spell(193531)
  local DeviousStratagem = Spell(394321)
  local SecretStratagem = Spell(394320)

  function Commons.CPMaxSpend()
    return 5 + (DeeperStratagem:IsAvailable() and 1 or 0) + (DeviousStratagem:IsAvailable() and 1 or 0) + (SecretStratagem:IsAvailable() and 1 or 0)
  end
end

-- "cp_spend"
function Commons.CPSpend()
  return mathmin(Player:ComboPoints(), Commons.CPMaxSpend())
end

-- "animacharged_cp"
do
  function Commons.AnimachargedCP()
    if Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand2) then
      return 2
    elseif Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand3) then
      return 3
    elseif Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand4) then
      return 4
    elseif Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand5) then
      return 5
    end

    return -1
  end

  function Commons.EffectiveComboPoints(ComboPoints)
    if ComboPoints == 2 and Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand2)
    or ComboPoints == 3 and Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand3)
    or ComboPoints == 4 and Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand4)
    or ComboPoints == 5 and Player:BuffUp(Spell.Rogue.Commons.EchoingReprimand5) then
      return 7
    end
    return ComboPoints
  end
end

-- poisoned
--[[ Original SimC Code
  return dots.deadly_poison -> is_ticking() ||
          debuffs.wound_poison -> check();
]]
do
  local DeadlyPoisonDebuff = Spell.Rogue.Assassination.DeadlyPoisonDebuff
  local WoundPoisonDebuff = Spell.Rogue.Assassination.WoundPoisonDebuff
  local AmplifyingPoisonDebuff = Spell.Rogue.Assassination.AmplifyingPoisonDebuff
  local CripplingPoisonDebuff = Spell.Rogue.Assassination.CripplingPoisonDebuff
  local AtrophicPoisonDebuff = Spell.Rogue.Assassination.AtrophicPoisonDebuff

  function Commons.Poisoned (ThisUnit)
    return (ThisUnit:DebuffUp(DeadlyPoisonDebuff) or ThisUnit:DebuffUp(AmplifyingPoisonDebuff) or ThisUnit:DebuffUp(CripplingPoisonDebuff)
      or ThisUnit:DebuffUp(WoundPoisonDebuff) or ThisUnit:DebuffUp(AtrophicPoisonDebuff)) and true or false
  end
end

-- poisoned_bleeds
--[[ Original SimC Code
  int poisoned_bleeds = 0;
  for ( size_t i = 0, actors = sim -> target_non_sleeping_list.size(); i < actors; i++ )
  {
    player_t* t = sim -> target_non_sleeping_list[i];
    rogue_td_t* tdata = get_target_data( t );
    if ( tdata -> lethal_poisoned() ) {
      poisoned_bleeds += tdata -> dots.garrote -> is_ticking() +
                          tdata -> dots.internal_bleeding -> is_ticking() +
                          tdata -> dots.rupture -> is_ticking();
    }
  }
  return poisoned_bleeds;
]]
do
  local Garrote = Spell.Rogue.Assassination.Garrote
  local GarroteDeathmark = Spell.Rogue.Assassination.GarroteDeathmark
  local Rupture = Spell.Rogue.Assassination.Rupture
  local RuptureDeathmark = Spell.Rogue.Assassination.RuptureDeathmark
  local InternalBleeding = Spell.Rogue.Assassination.InternalBleeding

  local PoisonedBleedsCount = 0
  function Commons.PoisonedBleeds ()
    PoisonedBleedsCount = 0
    for _, ThisUnit in pairs(Player:GetEnemiesInRange(50)) do
      if Commons.Poisoned(ThisUnit) then
        if ThisUnit:DebuffUp(Garrote) then
          PoisonedBleedsCount = PoisonedBleedsCount + 1
          if ThisUnit:DebuffUp(GarroteDeathmark) then
            PoisonedBleedsCount = PoisonedBleedsCount + 1
          end
        end
        if ThisUnit:DebuffUp(Rupture) then
          PoisonedBleedsCount = PoisonedBleedsCount + 1
          if ThisUnit:DebuffUp(RuptureDeathmark) then
            PoisonedBleedsCount = PoisonedBleedsCount + 1
          end
        end
        if ThisUnit:DebuffUp(InternalBleeding) then
          PoisonedBleedsCount = PoisonedBleedsCount + 1
        end
      end
    end
    return PoisonedBleedsCount
  end
end

--- ============================ HEADER ============================
--- ======= LOCALIZE =======
-- Addon
local addonName, addonTable = ...
  -- HeroLib
local HL = HeroLib
-- HeroRotation
local HR = HeroRotation
-- File Locals
local GUI = HL.GUI
local CreateChildPanel = GUI.CreateChildPanel
local CreatePanelOption = GUI.CreatePanelOption
local CreateARPanelOption = HR.GUI.CreateARPanelOption
local CreateARPanelOptions = HR.GUI.CreateARPanelOptions


--- ============================ CONTENT ============================
-- Default settings
HR.GUISettings.APL.Rogue = {
  Commons = {
    Enabled = {
      Potions = true,
      Trinkets = true,
      Items = true,
    },
    ShowStealthOOC = true,
    ShowPoisonOOC = true,
    CrimsonVialHP = 30,
    RangedMultiDoT = true, -- Suggest Multi-DoT at 10y Range
    UseSoloVanish = false, -- don't vanish while solo
    UseDPSVanish = true, -- allow the use of vanish for dps (checking for if you're solo)
    ShowPooling = true,
  },
  CommonsDS = {
    DisplayStyle = {
      -- Common
      Interrupts = "Cooldown",
      Items = "Suggested",
      Potions = "Suggested",
      Signature = "Main Icon",
      Trinkets = "Suggested",
      -- Class Specific
      Stealth = "Main Icon",
    },
  },
  CommonsOGCD = {
    GCDasOffGCD = {
      Blind = true,
      EchoingReprimand = false,
      CrimsonVial = true,
      Feint = true,
    },
    OffGCDasOffGCD = {
      Racials = true,
      Vanish = false,
      ShadowDance = true,
      ThistleTea = true,
      ColdBlood = true,
    }
  },
  Assassination = {
    EnvenomDMGOffset = 3,
    MutilateDMGOffset = 3,
    Envat50 = false,
    UsePriorityRotation = "Never", -- Only for Assassination / Subtlety
    PotionType = {
      Selected = "Power",
    },
    GCDasOffGCD = {
      Exsanguinate = false,
      Kingsbane = false,
      ShadowDance = false,
      Shiv = false,
    },
    OffGCDasOffGCD = {
      Deathmark = true,
      IndiscriminateCarnage = true,
    }
  },
  Outlaw = {
    -- Roll the Bones Logic, accepts "SimC", "1+ Buff" and every "RtBName".
    -- "SimC", "1+ Buff", "Broadside", "Buried Treasure", "Grand Melee", "Skull and Crossbones", "Ruthless Precision", "True Bearing"
    RolltheBonesLogic = "SimC",
    KillingSpreeDisplayStyle = "Suggested",
    PotionType = {
      Selected = "Power",
    },
    GCDasOffGCD = {
      BladeFlurry = false,
      BladeRush = false,
      KeepItRolling = false,
      RolltheBones = false,
      Sepsis = false,
    },
    OffGCDasOffGCD = {
      GhostlyStrike = false,
      AdrenalineRush = true,
    }
  },
  Subtlety = {
    EviscerateDMGOffset = 3, -- Used to compute the rupture threshold
    VanishFlagintoBlades = true,
    FunnelTindral = true,
    VanishafterSecret = true,
    BurnShadowDance = "On Bosses not in Dungeons", -- Burn Shadow Dance charges when the target is about to die
    UsePriorityRotation = "Auto", -- Only for Assassination / Subtlety
    PotionType = {
      Selected = "Power",
    },
    GCDasOffGCD = {
      ShurikenTornado = false,
    },
    OffGCDasOffGCD = {
      SymbolsofDeath = true,
      ShadowDance = true,
      ShadowBlades = true,
      Flagellation = true,
      Vanish = false,
    },
    StealthMacro = {
      Vanish = true,
      Shadowmeld = true,
      ShadowDance = true
    }
  }
}

HR.GUI.LoadSettingsRecursively(HR.GUISettings)

-- Child Panels
local ARPanel = HR.GUI.Panel
local CP_Rogue = CreateChildPanel(ARPanel, "Rogue")
local CP_RogueDS = CreateChildPanel(CP_Rogue, "Class DisplayStyles")
local CP_RogueOGCD = CreateChildPanel(CP_Rogue, "Class OffGCDs")
local CP_Assassination = CreateChildPanel(CP_Rogue, "Assassination")
local CP_Outlaw = CreateChildPanel(CP_Rogue, "Outlaw")
local CP_Subtlety = CreateChildPanel(CP_Rogue, "Subtlety")

-- Controls
-- Rogue
CreateARPanelOptions(CP_Rogue, "APL.Rogue.Commons")
CreatePanelOption("Slider", CP_Rogue, "APL.Rogue.Commons.CrimsonVialHP", {0, 100, 1}, "Crimson Vial HP", "Set the Crimson Vial HP threshold.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.ShowStealthOOC", "Stealth While OOC", "Suggest Stealth while out of combat.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.ShowPoisonOOC", "Poisons While OOC", "Suggest Poisons while out of combat.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.RangedMultiDoT", "Suggest Ranged Multi-DoT", "Suggest multi-DoT targets at Fan of Knives range (10 yards) instead of only melee range. Disabling will only suggest DoT targets within melee range.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.UseDPSVanish", "Use Vanish for DPS", "Suggest Vanish for DPS.\nDisable to save Vanish for utility purposes.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.UseSoloVanish", "Use Vanish while Solo", "Suggest Vanish while Solo.\nDisable to save prevent mobs resetting.")
CreatePanelOption("CheckButton", CP_Rogue, "APL.Rogue.Commons.ShowPooling", "Show Pooling Icon", "Show pooling icon instead of pooling prediction.")
CreateARPanelOptions(CP_RogueDS, "APL.Rogue.CommonsDS")
CreateARPanelOptions(CP_RogueOGCD, "APL.Rogue.CommonsOGCD")

-- Assassination
CreatePanelOption("Slider", CP_Assassination, "APL.Rogue.Assassination.EnvenomDMGOffset", {1, 5, 0.25}, "Envenom DMG Offset", "Set the Envenom DMG Offset.")
CreatePanelOption("Slider", CP_Assassination, "APL.Rogue.Assassination.MutilateDMGOffset", {1, 5, 0.25}, "Mutilate DMG Offset", "Set the Mutilate DMG Offset.")
CreatePanelOption("CheckButton", CP_Assassination, "APL.Rogue.Assassination.Envat50", "With this setting checked, you will only funnel to 50% Energy and use tea differently", "Check if you want to only funnel to 50% Energy till 10 seconds before CDs (it will try to funnel to 80% or use CDs when they are ready")
CreatePanelOption("Dropdown", CP_Assassination, "APL.Rogue.Assassination.UsePriorityRotation", {"Never", "On Bosses", "Always", "Auto"}, "Use Priority Rotation", "Select when to show rotation for maximum priority damage (at the cost of overall AoE damage.)\nAuto will function as Never except on specific encounters where AoE is not recommended.")
CreateARPanelOptions(CP_Assassination, "APL.Rogue.Assassination")

-- Outlaw
CreatePanelOption("Dropdown", CP_Outlaw, "APL.Rogue.Outlaw.RolltheBonesLogic", {"SimC", "1+ Buff", "Broadside", "Buried Treasure", "Grand Melee", "Skull and Crossbones", "Ruthless Precision", "True Bearing"}, "Roll the Bones Logic", "Define the Roll the Bones logic to follow.\n(SimC highly recommended!)")
CreatePanelOption("Dropdown", CP_Outlaw, "APL.Rogue.Outlaw.KillingSpreeDisplayStyle", {"Main Icon", "Suggested", "SuggestedRight", "Cooldown"}, "Killing Spree Display Style", "Define which icon display style to use for Killing Spree.")
CreateARPanelOptions(CP_Outlaw, "APL.Rogue.Outlaw")

-- Subtlety
CreatePanelOption("Slider", CP_Subtlety, "APL.Rogue.Subtlety.EviscerateDMGOffset", {1, 5, 0.25}, "Eviscerate Damage Offset", "Set the Eviscerate Damage Offset, used to compute the rupture threshold.")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.VanishFlagintoBlades", "Vanish to Flag into Blades at Fyrakk at 1:00-2:40", "Check if you want to use Vanish at around 1:00-1:10 and 2:40-2:50 after Flag to Pull Blades into Flag (currently not supported since you most often have enough Damage. but maybe for better push timings)")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.FunnelTindral", "Full Funnel on Tindral (MUST have priority rotation on Auto) If you do not want to funnel, do not tick this box", "Check if you want to full funnel on Tindral")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.VanishafterSecret", "Lets you do Vanish after Secret instead of after Dance to pull Blades sooner (not in the APL, people do it tho)", "Check if you want to Vanish after Secret in Dance")
CreatePanelOption("Dropdown", CP_Subtlety, "APL.Rogue.Subtlety.UsePriorityRotation", {"Never", "On Bosses", "Always", "Auto"}, "Use Priority Rotation", "Select when to show rotation for maximum priority damage (at the cost of overall AoE damage.)\nAuto will function as Never except on specific encounters where AoE is not recommended.")
CreatePanelOption("Dropdown", CP_Subtlety, "APL.Rogue.Subtlety.BurnShadowDance", {"Always", "On Bosses", "On Bosses not in Dungeons"}, "Burn Shadow Dance before Death", "Use remaining Shadow Dance charges when the target is about to die.")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.StealthMacro.Vanish", "Stealth Combo - Vanish", "Allow suggesting Vanish stealth ability combos (recommended)")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.StealthMacro.Shadowmeld", "Stealth Combo - Shadowmeld", "Allow suggesting Shadowmeld stealth ability combos (recommended)")
CreatePanelOption("CheckButton", CP_Subtlety, "APL.Rogue.Subtlety.StealthMacro.ShadowDance", "Stealth Combo - Shadow Dance", "Allow suggesting Shadow Dance stealth ability combos (recommended)")
CreateARPanelOptions(CP_Subtlety, "APL.Rogue.Subtlety")

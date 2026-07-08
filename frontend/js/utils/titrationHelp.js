// ============================================================================
// titrationHelp.js — plain-language tooltips + help-panel copy for the
// Titration & Separation module. Loaded as a global via <script>, like
// palettes.js. Access as TitrationHelp.metrics.auroc.tip, etc.
// ============================================================================

const TitrationHelp = {
  "_note": "Plain-language help for the Titration & Separation module. Each entry: tip = short hover text; what = what it is; read = how to read it. Written for users without a stats/spectral background.",

  "transform": {
    "arcsinh": {
      "label": "arcsinh values",
      "tip": "The honest brightness scale. Titration needs this.",
      "what": "Fluorescence intensity on an arcsinh scale, which keeps the real brightness of each cell.",
      "read": "Bigger number means brighter staining. This is what titration, staining index, and signal-to-background all use."
    },
    "why_arcsinh": {
      "label": "Why not z-score here?",
      "tip": "z-score erases brightness, which is exactly what titration measures.",
      "what": "A z-score re-centers every marker to zero and rescales it, which throws away absolute brightness and puts different populations on different scales.",
      "read": "Titration is about how bright the stain is and how far it sits above background, so this module always uses arcsinh and will warn you if it is handed z-scored data. Ranking metrics like AUROC are unaffected either way."
    }
  },

  "controls": {
    "blank": {
      "label": "Unstained blank (Q1)",
      "tip": "Sets the autofluorescence floor.",
      "what": "A sample with no antibody. It tells you how bright cells are on their own.",
      "read": "Signal above this floor confirms the antibody is doing something. It rises with every concentration, so it confirms detection but cannot pick the best concentration by itself."
    },
    "fmo": {
      "label": "FMO control (Q2)",
      "tip": "The best negative for picking a titer.",
      "what": "Full panel minus this one antibody. It accounts for spillover from other colors.",
      "read": "If you have this, titers are trustworthy. It is the preferred anchor for both thresholds and the peak staining index."
    },
    "single_stain": {
      "label": "Single-stain control (Q3)",
      "tip": "Checks spillover and spreading.",
      "what": "One antibody at a time, used to flag which channels carry background risk.",
      "read": "Feeds confidence in the result; it does not set the titer directly."
    },
    "full_stained_only": {
      "label": "Full-stained only (Q4)",
      "tip": "Fallback: uses an internal negative.",
      "what": "No dedicated negatives, so the app falls back to a within-well low-binding population or a biological negative such as apoptotic cells.",
      "read": "Usable, but internal negatives often co-stain, so the titer comes with a lower-confidence caveat. Add an FMO to firm it up."
    },
    "positive_picker": {
      "label": "Positive population",
      "tip": "The real cells that should stain.",
      "what": "The population you expect to carry true signal (for example PAX6-positive cells).",
      "read": "This is the 'A' in every comparison."
    },
    "negative_picker": {
      "label": "Negative population",
      "tip": "What 'no real signal' looks like.",
      "what": "The population used as background: FMO, within-well unstained, or a biological negative.",
      "read": "This is the 'B' in every comparison. The app checks its quality and warns if it looks contaminated."
    }
  },

  "metrics": {
    "staining_index": {
      "label": "Staining index (SI)",
      "tip": "How far signal sits above background, in noise units.",
      "what": "The gap between the positive and negative medians, divided by the spread of the negative.",
      "read": "Higher is better separation. The best concentration is usually where SI peaks. If the negative is broad or bright, SI shrinks even when staining is fine, so read it alongside AUROC."
    },
    "auroc": {
      "label": "AUROC (separation)",
      "tip": "Chance a real cell is brighter than a negative cell.",
      "what": "A rank-based separation score from 0 to 1.",
      "read": "0.5 means no separation (overlap). Above 0.7 is clear separation. Below 0.5 means the negative is brighter than the real cells, which is a warning sign about the negative or the antibody. AUROC does not care about the transform, so it is robust."
    },
    "sbr": {
      "label": "Signal-to-background (SBR)",
      "tip": "How many times brighter the real cells are.",
      "what": "The ratio of the positive median to the negative median.",
      "read": "Above 1 means real cells are brighter. At or below 1 at mid-to-high concentration means extra antibody is just adding background."
    },
    "pct_above_p95": {
      "label": "% above background",
      "tip": "Share of real cells clearly above the negative.",
      "what": "Percent of positive cells brighter than the 95th percentile of the negative.",
      "read": "Higher means a cleaner, more separated positive population."
    },
    "saturation_knee": {
      "label": "Saturation knee",
      "tip": "Where adding antibody stops helping.",
      "what": "The concentration after which median brightness barely increases.",
      "read": "Good working titer for brightness. If there is no knee, the stain never plateaued and you may need a stronger top concentration."
    },
    "cv": {
      "label": "%CV of the positive",
      "tip": "How tight the positive population is.",
      "what": "Spread of the positive population relative to its center, per concentration.",
      "read": "Lower is a more uniform stain. Rising %CV at high concentration can signal aggregation or nonspecific binding."
    },
    "detection_vs_specificity": {
      "label": "Detection vs specificity",
      "tip": "Two separate questions, reported separately.",
      "what": "Detection = real cells vs the blank floor. Specificity = real cells vs an antibody-receiving background.",
      "read": "Detection rising confirms the antibody works but always climbs with concentration. Specificity is what actually picks the titer. We keep them apart so a strong detection signal cannot hide a weak specificity signal."
    }
  },

  "flags": {
    "co_staining": {
      "label": "Co-staining",
      "tip": "The negative brightens with the real cells.",
      "read": "Separation never really opens up, so the titer is unreliable. Try a cleaner negative."
    },
    "inversion": {
      "label": "Inversion",
      "tip": "The negative is brighter than the real cells.",
      "read": "Usually a bad negative (for example apoptotic cells trap antibody), not necessarily a bad antibody. Confirm with an FMO or secondary-only control."
    },
    "non_saturation": {
      "label": "Non-saturating",
      "tip": "Still getting brighter at the top concentration.",
      "read": "The best concentration may be stronger than anything you tested. Consider a more concentrated top point."
    },
    "specificity_loss": {
      "label": "Specificity loss",
      "tip": "Background catches up at high concentration.",
      "read": "At mid-to-high concentration the negative is as bright as the real cells, so more antibody buys background, not signal."
    }
  },

  "quality": {
    "negative_quality": {
      "label": "Negative quality",
      "tip": "Is the negative trustworthy?",
      "what": "Where the negative sits between the blank floor (clean) and the positive (contaminated).",
      "read": "Clean means it behaves like true background. Contaminated means it is nearly as bright as the real cells, so titers built on it are provisional."
    },
    "confidence": {
      "label": "Confidence",
      "tip": "How much to trust the titer.",
      "what": "Scales with which controls exist and how clean the negative is.",
      "read": "High with an FMO, moderate with a within-well negative plus a blank, low when only a co-staining internal negative is available."
    }
  }
};

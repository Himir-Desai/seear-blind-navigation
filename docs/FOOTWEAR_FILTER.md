# B4: wearer footwear and misleading near-distance alerts

The reported cap setup is about 5–6 ft above the floor, with forward and downward RGB cameras. Previously every supported raised surface could become an obstacle, including the wearer's own shoes. The feet default was 55° down and the configuration rejected 90°, despite a straight-down mount being valid. B4 supports −30°…90° and defaults feet to 90°; use the actual angle if the mount is tilted. Camera height, FOV and depth scale still need to match the real setup.

Distances in guidance are **horizontal ground ranges** from the camera's vertical projection, not optical depth or camera-to-object slant range. A shoe 0.2 m ahead can be about 1.5 m from a head-mounted camera. Increasing all distances or suppressing everything under a minimum range would obscure the problem. Obstacle debug text now names the source camera and says “horizontally”. This change does not establish or improve general metric depth accuracy.

## Implemented filter

Feet frames automatically query `shoe` and `leg` using the already cached local OWLv2 model, including when no item is being searched for. Item, shoe and leg scores are processed independently; an active item shares the image-model pass. The normal front-camera detector contract remains unchanged. All three query shapes are warmed before live readiness.

A footwear candidate needs a shoe score ≥0.20, a modest box size and majority support inside the estimated body region: lateral ±0.38 m, forward −0.25…0.65 m, height 0.025…0.40 m. A foreground segmentation uses RGB, the detection box, central depth support and a depth band (max of 8 cm or 6% of seed depth). Floor, higher and different-depth pixels are background. It does not erase an entire shoe box or a fixed near-foot zone. Segmentation failure retains occupancy.

Lower-leg candidates need score ≥0.25 and an adjacent accepted shoe, with their own lateral/forward/height constraints. Oversized boxes are rejected, and a combined mask over 30% of the image is rejected. These are provisional engineering gates. Only masked pixels leave the obstacle occupancy calculation; valid-depth coverage and item-finder observations are unchanged. No mask persists into a subsequent frame. Without usable shoe evidence, pixels remain eligible for alerts. The debug status reports candidate shoes and the number of excluded pixels.

Category detection and near-body geometry do **not** prove ownership. A loose shoe or another person's footwear inside the body region can be mistaken for worn footwear; a missed detection can still alert on the wearer's shoe. RGB foreground segmentation, monocular depth, scale error and mount error can also suppress or retain incorrect pixels. No physical footwear-filter accuracy or stopping-distance guarantee is claimed. The same 1.5 s live freshness cutoff still applies.

## Validation and physical regression

Synthetic tests must reproduce the original near-shoe false hazard, remove its occupancy, preserve a nearby low obstacle, preserve a closer object inside the shoe box, retain distant/front-feed footwear, require shoe support for leg masks, retain occupancy on weak/missing evidence or segmentation failure, preserve target finding and valid-depth coverage, and exercise neutral-mode worker integration. Analytic geometry tests include 5–6 ft heights and a 90° camera.

The real-model smoke check exercises the additional footwear queries and native filter-metadata decoding while retaining the target/depth checks and live timing deadline. Public sample images and synthetic depth/boxes do not demonstrate reliable recognition of the actual wearer's shoes.

For the supervised hardware recheck, verify the measured height/angle first, then stand still with both shoes visible and observe candidate/pixel counts. Test several shoe/pants colors, a slow step and head turn. Place a low block beside and ahead of a shoe, a chair leg close by and a loose shoe farther ahead; verify their alerts remain. Check backpack/cane finding at the same time. Record failures and range error at known distances before walking trials.

Primary model references: [OWLv2 detection API](https://huggingface.co/docs/transformers/model_doc/owlv2), [metric depth model](https://huggingface.co/depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf). Masking is this project's heuristic; those references do not validate wearer identification.

B6 applies the same capture-time head tilt as live obstacle geometry before near-body checks. The fixed camera mount angle is unchanged; nodding/rolling does not move the estimated floor or footwear volume with the image. A cap slipping relative to the head, unknown body heading or inaccurate RGB depth can still invalidate that heuristic.

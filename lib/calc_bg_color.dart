/// Makes user-uploaded logos readable on any background.
///
/// Quick start:
///
/// ```dart
/// import 'package:calc_bg_color/calc_bg_color.dart';
///
/// // As a widget:
/// AdaptiveLogo(image: NetworkImage(url), background: Colors.white);
///
/// // Without widgets:
/// final logo = await LogoAnalyzer.prepare(NetworkImage(url));
/// final result = logo.evaluate(Colors.white);
/// print(result.hasConflict);
/// print(result.recommendedBackground);
/// ```
///
/// Folder map (read in this order to learn the package):
///
/// * `src/color/`    color formulas (luminance, contrast, OKLab)
/// * `src/image/`    the raw pixel container
/// * `src/steps/`    one file per processing step, each usable alone
/// * `src/pipeline/` runs the steps in order (pure Dart)
/// * `src/flutter/`  loads Flutter images and encodes PNG
/// * `src/widgets/`  ready-made widgets
library;

export 'src/color/color_math.dart';
export 'src/flutter/logo_analyzer.dart';
export 'src/image/rgba_image.dart';
export 'src/pipeline/logo_pipeline.dart';
export 'src/steps/background_recommender.dart';
export 'src/steps/background_remover.dart';
export 'src/steps/border_detector.dart';
export 'src/steps/contrast_checker.dart';
export 'src/steps/palette_extractor.dart';
export 'src/steps/trimmer.dart';
export 'src/widgets/adaptive_logo.dart';
export 'src/widgets/logo_halo.dart';

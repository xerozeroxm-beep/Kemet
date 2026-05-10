import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GeminiService {
  static String? get _apiKey {
    final key = dotenv.env['GEMINI_API_KEY'];
    if (key == null || key.trim().isEmpty) return null;
    return key;
  }

  GenerativeModel? get _model {
    final apiKey = _apiKey;
    if (apiKey == null) return null;
    return GenerativeModel(model: 'gemini-2.5-flash', apiKey: apiKey);
  }

  Future<Map<String, dynamic>?> getCropDetails(String cropName) async {
    final prompt = '''
You are a precision agriculture data service. Your job is to return standardized crop growing parameters.

Plant to look up: "$cropName"

If this is not a real, cultivatable crop or plant name, return exactly:
{"error": "invalid"}

If it is a valid crop, return ONLY a JSON object using the exact thresholds published by recognized agricultural authorities (FAO irrigation guides, USDA crop profiles, Wageningen University crop databases, or manufacturer EC guidelines from Hoagland solution standards).

Rules:
- Values must be fixed and consistent — do NOT vary them between requests for the same crop.
- Use the most widely cited, peer-reviewed midpoint values for that crop species.
- min_moisture and max_moisture: soil volumetric water content percentage (typical greenhouse substrate), integers.
- min_ec and max_ec: electrical conductivity in mS/cm (root-zone nutrient solution), rounded to 1 decimal.
- icon_code: a Material Icons codepoint (decimal integer) that visually represents this crop. Pick a stable, fitting icon.

Return ONLY this JSON, no explanation, no markdown:
{"min_moisture": int, "max_moisture": int, "min_ec": double, "max_ec": double, "icon_code": int}

Reference values for common crops (use these exact numbers):
- Tomato: min_moisture=65, max_moisture=85, min_ec=2.0, max_ec=4.0, icon_code=59654
- Cucumber: min_moisture=70, max_moisture=85, min_ec=1.7, max_ec=2.5, icon_code=57820
- Pepper: min_moisture=65, max_moisture=80, min_ec=2.0, max_ec=3.5, icon_code=59654
- Lettuce: min_moisture=70, max_moisture=80, min_ec=0.8, max_ec=1.6, icon_code=60293
- Spinach: min_moisture=70, max_moisture=80, min_ec=1.8, max_ec=2.3, icon_code=60293
- Strawberry: min_moisture=60, max_moisture=80, min_ec=1.0, max_ec=1.4, icon_code=59403
- Watermelon: min_moisture=60, max_moisture=85, min_ec=1.5, max_ec=2.5, icon_code=59239
- Banana: min_moisture=65, max_moisture=85, min_ec=1.0, max_ec=1.5, icon_code=58926
- Wheat: min_moisture=60, max_moisture=80, min_ec=1.2, max_ec=2.5, icon_code=58132
- Blueberry: min_moisture=60, max_moisture=80, min_ec=0.8, max_ec=1.8, icon_code=59657
- Pineapple: min_moisture=60, max_moisture=80, min_ec=1.2, max_ec=2.5, icon_code=57763
- Basil: min_moisture=65, max_moisture=80, min_ec=1.0, max_ec=1.6, icon_code=57992
- Cannabis: min_moisture=60, max_moisture=75, min_ec=1.0, max_ec=2.5, icon_code=57792
- Rose: min_moisture=60, max_moisture=80, min_ec=1.5, max_ec=2.5, icon_code=59389
- Potato: min_moisture=65, max_moisture=80, min_ec=2.0, max_ec=2.5, icon_code=58726
- Carrot: min_moisture=65, max_moisture=80, min_ec=1.4, max_ec=2.0, icon_code=58726
- Onion: min_moisture=60, max_moisture=80, min_ec=1.0, max_ec=1.8, icon_code=58726
- Corn/Maize: min_moisture=65, max_moisture=85, min_ec=1.1, max_ec=1.7, icon_code=58132
- Grape: min_moisture=60, max_moisture=80, min_ec=1.0, max_ec=1.5, icon_code=57734
- Mango: min_moisture=60, max_moisture=80, min_ec=1.0, max_ec=2.0, icon_code=59403

For any other valid crop not in this list, use the closest FAO/USDA published guideline and return consistent, fixed values.
''';

    try {
      final model = _model;
      if (model == null) {
        return {"error": "missing_api_key"};
      }

      final response = await model.generateContent([Content.text(prompt)]);
      final rawText = (response.text ?? '').trim();
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(
        rawText.replaceAll('```json', '').replaceAll('```', ''),
      );
      if (jsonMatch == null) {
        return {"error": "invalid"};
      }

      final data = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

      if (data.containsKey('error')) return data;

      // Normalize keys from prompt format to internal app format
      return {
        'min_m': (data['min_moisture'] as num).toDouble(),
        'max_m': (data['max_moisture'] as num).toDouble(),
        'min_ec': (data['min_ec'] as num).toDouble(),
        'max_ec': (data['max_ec'] as num).toDouble(),
        // FIX 2: Gemini may return icon_code as a JSON double (e.g. 59654.0).
        // `as int` would throw a TypeError in that case; going via num is safe
        // for both int and double JSON values.
        'icon_code': (data['icon_code'] as num).toInt(),
      };
    } catch (e) {
      return {"error": "invalid"};
    }
  }
}

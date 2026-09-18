List<String> validateAttributeValues(
    Map<String, dynamic> values, List<dynamic> schema) {
  final errors = <String>[];
  final schemaByKey = <String, String>{};
  for (final element in schema) {
    if (element is Map && element['key'] is String && element['type'] is String) {
      schemaByKey[element['key'] as String] = element['type'] as String;
    }
  }

  for (final entry in values.entries) {
    final key = entry.key;
    final type = schemaByKey[key];
    if (type == null) {
      errors.add('unknown_attribute: $key');
      continue;
    }
    final value = entry.value;
    switch (type) {
      case 'number':
        if (value is! num) {
          errors.add('invalid_type: $key');
        }
        break;
      case 'bool':
        if (value is! bool) {
          errors.add('invalid_type: $key');
        }
        break;
      case 'text':
        if (value is! String) {
          errors.add('invalid_type: $key');
        }
        break;
      case 'date':
        if (value is! String || DateTime.tryParse(value) == null) {
          errors.add('invalid_type: $key');
        }
        break;
    }
  }
  return errors;
}
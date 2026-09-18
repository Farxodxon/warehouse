const _allowedSchemaTypes = {'text', 'number', 'bool', 'date'};

bool isValidAttributeSchema(dynamic value) {
  if (value is! List) return false;
  final seenKeys = <String>{};
  for (final element in value) {
    if (element is! Map) return false;
    final key = element['key'];
    final type = element['type'];
    if (key is! String || key.isEmpty) return false;
    if (type is! String || !_allowedSchemaTypes.contains(type)) return false;
    if (!seenKeys.add(key)) return false;
  }
  return true;
}
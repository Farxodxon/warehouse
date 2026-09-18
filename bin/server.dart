import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';

import 'package:wms_backend/auth/authorization.dart';
import 'package:wms_backend/auth/jwt.dart';
import 'package:wms_backend/auth/middleware.dart';
import 'package:wms_backend/auth/password.dart';
import 'package:wms_backend/db/connection.dart';
import 'package:wms_backend/products/attribute_schema.dart';
import 'package:wms_backend/products/attribute_values.dart';
import 'package:wms_backend/products/location_code.dart';

final _router = Router()
  ..get('/health', _healthHandler)
  ..post('/setup', _setupHandler)
  ..post('/login', _loginHandler)
  ..get('/me', authMiddleware()(_meHandler))
  ..get('/warehouses', authMiddleware()(_listWarehousesHandler))
  ..post('/warehouses', authMiddleware()(_createWarehouseHandler))
  ..get('/warehouses/<id>', authMiddleware()(_getWarehouseHandler))
  ..post('/warehouses/<id>/users', authMiddleware()(_assignUserToWarehouseHandler))
  ..get('/warehouses/<id>/users', authMiddleware()(_listWarehouseUsersHandler))
  ..get('/product-categories',
      authMiddleware()(_listProductCategoriesHandler))
  ..post('/product-categories',
      authMiddleware()(_createProductCategoryHandler))
  ..get('/product-categories/<id>',
      authMiddleware()(_getProductCategoryHandler))
  ..get('/products', authMiddleware()(_listProductsHandler))
  ..post('/products', authMiddleware()(_createProductHandler))
  ..get('/products/barcode/<barcode>',
      authMiddleware()(_getProductByBarcodeHandler))
  ..get('/products/<id>', authMiddleware()(_getProductHandler))
  ..put('/products/<id>', authMiddleware()(_updateProductHandler))
  ..get('/warehouses/<id>/zones', authMiddleware()(_listZonesHandler))
  ..post('/warehouses/<id>/zones', authMiddleware()(_createZoneHandler))
  ..get('/warehouses/<id>/storage-locations',
      authMiddleware()(_listStorageLocationsHandler))
  ..post('/warehouses/<id>/storage-locations',
      authMiddleware()(_createStorageLocationHandler))
  ..get('/storage-locations/code/<code>',
      authMiddleware()(_getStorageLocationByCodeHandler))
  ..get('/storage-locations/<id>',
      authMiddleware()(_getStorageLocationHandler));

Response _jsonResponse(int statusCode, String body) {
  return Response(statusCode,
      body: body,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

Response _jsonResponseBody(int statusCode, Map<String, dynamic> body) {
  return _jsonResponse(statusCode, jsonEncode(body));
}

Future<Response> _healthHandler(Request request) async {
  try {
    final connection = await openConnection();
    await connection.execute('SELECT 1');
    await connection.close();
    return _jsonResponse(200, '{"status":"ok","database":"connected"}');
  } catch (e, st) {
    stderr.writeln('DB health check error: $e\n$st');
    return _jsonResponse(503, '{"status":"error","database":"disconnected"}');
  }
}

Future<Response> _setupHandler(Request request) async {
  try {
    final connection = await openConnection();
    try {
      final countResult = await connection.query('SELECT COUNT(*) FROM users');
      final count = countResult.first.first;
      final countInt = count is BigInt ? count.toInt() : count as int;
      if (countInt > 0) {
        return _jsonResponse(403, '{"error":"already_initialized"}');
      }

      final body = jsonDecode(await request.readAsString());
      final email = body['email'] as String;
      final password = body['password'] as String;
      final fullName = body['full_name'] as String;
      final role = 'super_admin';

      final hash = hashPassword(password);
      final result = await connection.query(
        'INSERT INTO users (email, password_hash, full_name, role) '
        'VALUES (@email, @hash, @fullName, @role) '
        'RETURNING id',
        substitutionValues: {
          'email': email,
          'hash': hash,
          'fullName': fullName,
          'role': role,
        },
      );
      final id = result.first.first as int;

      return _jsonResponseBody(201,
          {'id': id, 'email': email, 'full_name': fullName, 'role': role});
    } finally {
      await connection.close();
    }
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
}

Future<Response> _loginHandler(Request request) async {
  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final email = body['email'] as String? ?? '';
  final password = body['password'] as String? ?? '';

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, email, password_hash, full_name, role FROM users '
      'WHERE email = @email',
      substitutionValues: {'email': email},
    );

    if (result.isEmpty) {
      return _jsonResponse(401, '{"error":"invalid_credentials"}');
    }

    final row = result.first;
    final passwordHash = row[2] as String;
    if (!verifyPassword(password, passwordHash)) {
      return _jsonResponse(401, '{"error":"invalid_credentials"}');
    }

    final id = row[0] as int;
    final token = generateToken(id, email);

    return _jsonResponseBody(200, {
      'token': token,
      'user': {
        'id': id,
        'email': row[1],
        'full_name': row[3],
        'role': row[4],
      },
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _meHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, email, full_name, role, organization_id FROM users '
      'WHERE id = @id',
      substitutionValues: {'id': userId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }
    final row = result.first;
    return _jsonResponseBody(200, {
      'id': row[0],
      'email': row[1],
      'full_name': row[2],
      'role': row[3],
      'organization_id': row[4],
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _listWarehousesHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final isSuper = await isSuperAdmin(userId);

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT w.id, w.name, w.address, w.city, uwa.role '
      'FROM warehouses w '
      'LEFT JOIN user_warehouse_access uwa '
      '  ON uwa.warehouse_id = w.id AND uwa.user_id = @userId '
      'WHERE @isSuper = TRUE OR uwa.id IS NOT NULL '
      'ORDER BY w.id',
      substitutionValues: {'userId': userId, 'isSuper': isSuper},
    );

    final warehouses = <Map<String, dynamic>>[];
    for (final row in result) {
      final role = row[4] as String? ?? (isSuper ? 'super_admin' : null);
      warehouses.add({
        'id': row[0],
        'name': row[1],
        'address': row[2],
        'city': row[3],
        'role': role,
      });
    }
    return _jsonResponse(200, jsonEncode(warehouses));
  } finally {
    await connection.close();
  }
}

Future<Response> _createWarehouseHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await isSuperAdmin(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final name = body['name'] as String?;
  final address = body['address'] as String?;
  final city = body['city'] as String?;
  if (name == null || name.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final orgResult = await connection.query(
      'SELECT organization_id FROM users WHERE id = @userId',
      substitutionValues: {'userId': userId},
    );
    if (orgResult.isEmpty || orgResult.first.first == null) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }
    final organizationId = orgResult.first.first as int;

    final insertResult = await connection.query(
      'INSERT INTO warehouses (organization_id, name, address, city) '
      'VALUES (@organizationId, @name, @address, @city) RETURNING id',
      substitutionValues: {
        'organizationId': organizationId,
        'name': name,
        'address': address,
        'city': city,
      },
    );
    final warehouseId = insertResult.first.first as int;

    await connection.execute(
      'INSERT INTO user_warehouse_access (user_id, warehouse_id, role) '
      'VALUES (@userId, @warehouseId, @role)',
      substitutionValues: {
        'userId': userId,
        'warehouseId': warehouseId,
        'role': 'warehouse_manager',
      },
    );

    return _jsonResponseBody(201, {
      'id': warehouseId,
      'name': name,
      'address': address,
      'city': city,
      'role': 'warehouse_manager',
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _getWarehouseHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, name, address, city FROM warehouses WHERE id = @id',
      substitutionValues: {'id': warehouseId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final isSuper = await isSuperAdmin(userId);
    final role = await getUserRoleForWarehouse(userId, warehouseId);
    if (!isSuper && role == null) {
      return _jsonResponse(403, '{"error":"forbidden"}');
    }

    final row = result.first;
    return _jsonResponseBody(200, {
      'id': row[0],
      'name': row[1],
      'address': row[2],
      'city': row[3],
      'role': role ?? 'super_admin',
    });
  } finally {
    await connection.close();
  }
}

const _allowedWarehouseRoles = [
  'super_admin',
  'warehouse_manager',
  'operator',
  'viewer',
];

Future<Response> _assignUserToWarehouseHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final targetUserId = body['user_id'] as int?;
  final role = body['role'] as String?;
  if (targetUserId == null ||
      role == null ||
      !_allowedWarehouseRoles.contains(role)) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final warehouseResult = await connection.query(
      'SELECT id FROM warehouses WHERE id = @id',
      substitutionValues: {'id': warehouseId},
    );
    if (warehouseResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final isSuper = await isSuperAdmin(userId);
    final managerRole = await getUserRoleForWarehouse(userId, warehouseId);
    if (!isSuper && managerRole != 'warehouse_manager') {
      return _jsonResponse(403, '{"error":"forbidden"}');
    }

    final userResult = await connection.query(
      'SELECT id FROM users WHERE id = @id',
      substitutionValues: {'id': targetUserId},
    );
    if (userResult.isEmpty) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }

    final existing = await connection.query(
      'SELECT id FROM user_warehouse_access '
      'WHERE user_id = @userId AND warehouse_id = @warehouseId',
      substitutionValues: {'userId': targetUserId, 'warehouseId': warehouseId},
    );
    if (existing.isNotEmpty) {
      return _jsonResponse(409, '{"error":"already_assigned"}');
    }

    final insertResult = await connection.query(
      'INSERT INTO user_warehouse_access (user_id, warehouse_id, role) '
      'VALUES (@userId, @warehouseId, @role) RETURNING id',
      substitutionValues: {
        'userId': targetUserId,
        'warehouseId': warehouseId,
        'role': role,
      },
    );

    return _jsonResponseBody(201, {
      'id': insertResult.first.first,
      'user_id': targetUserId,
      'warehouse_id': warehouseId,
      'role': role,
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _listWarehouseUsersHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final warehouseResult = await connection.query(
      'SELECT id FROM warehouses WHERE id = @id',
      substitutionValues: {'id': warehouseId},
    );
    if (warehouseResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final isSuper = await isSuperAdmin(userId);
    final accessRole = await getUserRoleForWarehouse(userId, warehouseId);
    if (!isSuper && accessRole == null) {
      return _jsonResponse(403, '{"error":"forbidden"}');
    }

    final result = await connection.query(
      'SELECT u.id, u.email, u.full_name, uwa.role '
      'FROM user_warehouse_access uwa '
      'JOIN users u ON u.id = uwa.user_id '
      'WHERE uwa.warehouse_id = @warehouseId '
      'ORDER BY u.id',
      substitutionValues: {'warehouseId': warehouseId},
    );

    final users = result
        .map((row) => {
              'id': row[0],
              'email': row[1],
              'full_name': row[2],
              'role': row[3],
            })
        .toList();
    return _jsonResponse(200, jsonEncode(users));
  } finally {
    await connection.close();
  }
}

const _allowedProductTypes = {
  'raw_material',
  'semi_finished',
  'finished_good',
  'other',
};

Map<String, dynamic> _rowToProductCategory(List row) {
  return {
    'id': row[0],
    'organization_id': row[1],
    'name': row[2],
    'product_type': row[3],
    'attribute_schema': row[4],
    'created_at': (row[5] as DateTime).toUtc().toIso8601String(),
  };
}

Future<int?> _getUserOrganizationId(
    dynamic connection, int userId) async {
  final result = await connection.query(
    'SELECT organization_id FROM users WHERE id = @userId',
    substitutionValues: {'userId': userId},
  );
  if (result.isEmpty || result.first.first == null) return null;
  return result.first.first as int;
}

Future<Response> _listProductCategoriesHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'SELECT id, organization_id, name, product_type, attribute_schema, '
      'created_at FROM product_categories WHERE organization_id = @orgId '
      'ORDER BY id',
      substitutionValues: {'orgId': organizationId},
    );

    final categories = <Map<String, dynamic>>[];
    for (final row in result) {
      categories.add(_rowToProductCategory(row));
    }
    return _jsonResponse(200, jsonEncode(categories));
  } finally {
    await connection.close();
  }
}

Future<Response> _createProductCategoryHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await isSuperAdmin(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final name = body['name'] as String?;
  final productType = body['product_type'] as String?;
  final attributeSchema = body['attribute_schema'];
  if (name == null || name.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (productType == null ||
      !_allowedProductTypes.contains(productType)) {
    return _jsonResponse(400, '{"error":"invalid_product_type"}');
  }
  if (!isValidAttributeSchema(attributeSchema)) {
    return _jsonResponse(400, '{"error":"invalid_attribute_schema"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'INSERT INTO product_categories '
      '(organization_id, name, product_type, attribute_schema) '
      'VALUES (@orgId, @name, @productType, @schema::jsonb) '
      'RETURNING id, organization_id, name, product_type, attribute_schema, created_at',
      substitutionValues: {
        'orgId': organizationId,
        'name': name,
        'productType': productType,
        'schema': jsonEncode(attributeSchema),
      },
    );

    return _jsonResponse(201, jsonEncode(_rowToProductCategory(result.first)));
  } finally {
    await connection.close();
  }
}

Future<Response> _getProductCategoryHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final categoryId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'SELECT id, organization_id, name, product_type, attribute_schema, '
      'created_at FROM product_categories '
      'WHERE id = @id AND organization_id = @orgId',
      substitutionValues: {'id': categoryId, 'orgId': organizationId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

return _jsonResponse(
            200, jsonEncode(_rowToProductCategory(result.first)));
  } finally {
    await connection.close();
  }
}

Map<String, dynamic> _rowToProduct(List row, String categoryName) {
  return {
    'id': row[0],
    'organization_id': row[1],
    'category_id': row[2],
    'sku': row[3],
    'barcode': row[4],
    'name': row[5],
    'unit': row[6],
    'min_stock': _toNumOrNull(row[7]),
    'max_stock': _toNumOrNull(row[8]),
    'default_shelf_life_days': row[9],
    'attributes': row[10],
    'created_at': (row[11] as DateTime).toUtc().toIso8601String(),
    'category_name': categoryName,
  };
}

num? _toNumOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

Future<bool> _canManageProducts(int userId) async {
  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT role FROM users WHERE id = @userId',
      substitutionValues: {'userId': userId},
    );
    if (result.isEmpty) return false;
    if (result.first.first == 'super_admin') return true;

    final accessResult = await connection.query(
      'SELECT 1 FROM user_warehouse_access '
      'WHERE user_id = @userId AND role = \'warehouse_manager\' LIMIT 1',
      substitutionValues: {'userId': userId},
    );
    return accessResult.isNotEmpty;
  } finally {
    await connection.close();
  }
}

Future<Response> _listProductsHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final categoryId = int.tryParse(request.url.queryParameters['category_id'] ?? '');
    final search = request.url.queryParameters['search']?.trim();

    final conditions = <String>['p.organization_id = @orgId'];
    final values = <String, dynamic>{'orgId': organizationId};
    if (categoryId != null) {
      conditions.add('p.category_id = @categoryId');
      values['categoryId'] = categoryId;
    }
    if (search != null && search.isNotEmpty) {
      conditions.add('(p.name ILIKE @search OR p.sku ILIKE @search)');
      values['search'] = '%$search%';
    }

    final result = await connection.query(
      'SELECT p.id, p.organization_id, p.category_id, p.sku, p.barcode, '
      'p.name, p.unit, p.min_stock, p.max_stock, p.default_shelf_life_days, '
      'p.attributes, p.created_at, c.name '
      'FROM products p '
      'JOIN product_categories c ON c.id = p.category_id '
      'WHERE ${conditions.join(' AND ')} '
      'ORDER BY p.id',
      substitutionValues: values,
    );

    final products = result
        .map((row) => _rowToProduct(row, row[12] as String))
        .toList();
    return _jsonResponse(200, jsonEncode(products));
  } finally {
    await connection.close();
  }
}

Future<Response> _createProductHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canManageProducts(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final categoryId = body['category_id'];
  final sku = body['sku'];
  final name = body['name'];
  final unit = body['unit'];
  if (categoryId is! int ||
      sku is! String ||
      sku.isEmpty ||
      name is! String ||
      name.isEmpty ||
      unit is! String ||
      unit.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final barcode = body['barcode'];
  final minStock = body['min_stock'];
  final maxStock = body['max_stock'];
  final defaultShelfLifeDays = body['default_shelf_life_days'];
  final attributes = body['attributes'];
  if (minStock != null && minStock is! num) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (maxStock != null && maxStock is! num) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (defaultShelfLifeDays != null && defaultShelfLifeDays is! int) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (attributes == null || attributes is! Map) {
    return _jsonResponse(400, '{"error":"invalid_attributes","details":["attributes must be an object"]}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final categoryResult = await connection.query(
      'SELECT attribute_schema FROM product_categories '
      'WHERE id = @categoryId AND organization_id = @orgId',
      substitutionValues: {'categoryId': categoryId, 'orgId': organizationId},
    );
    if (categoryResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }
    final schema = categoryResult.first.first as List;

    final errors = validateAttributeValues(
        Map<String, dynamic>.from(attributes), schema);
    if (errors.isNotEmpty) {
      return _jsonResponse(
          400,
          jsonEncode({'error': 'invalid_attributes', 'details': errors}));
    }

    final existing = await connection.query(
      'SELECT 1 FROM products '
      'WHERE organization_id = @orgId AND sku = @sku',
      substitutionValues: {'orgId': organizationId, 'sku': sku},
    );
    if (existing.isNotEmpty) {
      return _jsonResponse(409, '{"error":"sku_already_exists"}');
    }

    final result = await connection.query(
      'INSERT INTO products '
      '(organization_id, category_id, sku, barcode, name, unit, min_stock, '
      'max_stock, default_shelf_life_days, attributes) '
      'VALUES (@orgId, @categoryId, @sku, @barcode, @name, @unit, @minStock, '
      '@maxStock, @defaultShelfLifeDays, @attributes::jsonb) '
      'RETURNING id, organization_id, category_id, sku, barcode, name, unit, '
      'min_stock, max_stock, default_shelf_life_days, attributes, created_at',
      substitutionValues: {
        'orgId': organizationId,
        'categoryId': categoryId,
        'sku': sku,
        'barcode': barcode,
        'name': name,
        'unit': unit,
        'minStock': minStock,
        'maxStock': maxStock,
        'defaultShelfLifeDays': defaultShelfLifeDays,
        'attributes': jsonEncode(attributes),
      },
    );

    final categoryName = (await connection.query(
      'SELECT name FROM product_categories WHERE id = @categoryId',
      substitutionValues: {'categoryId': categoryId},
    ))
        .first
        .first as String;

    return _jsonResponse(
        201, jsonEncode(_rowToProduct(result.first, categoryName)));
  } finally {
    await connection.close();
  }
}

Future<Response> _getProductHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final productId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'SELECT p.id, p.organization_id, p.category_id, p.sku, p.barcode, '
      'p.name, p.unit, p.min_stock, p.max_stock, p.default_shelf_life_days, '
      'p.attributes, p.created_at, c.name '
      'FROM products p '
      'JOIN product_categories c ON c.id = p.category_id '
      'WHERE p.id = @id AND p.organization_id = @orgId',
      substitutionValues: {'id': productId, 'orgId': organizationId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final row = result.first;
    return _jsonResponse(
        200, jsonEncode(_rowToProduct(row, row[12] as String)));
  } finally {
    await connection.close();
  }
}

Future<Response> _getProductByBarcodeHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final barcode = request.params['barcode']!;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'SELECT p.id, p.organization_id, p.category_id, p.sku, p.barcode, '
      'p.name, p.unit, p.min_stock, p.max_stock, p.default_shelf_life_days, '
      'p.attributes, p.created_at, c.name '
      'FROM products p '
      'JOIN product_categories c ON c.id = p.category_id '
      'WHERE p.barcode = @barcode AND p.organization_id = @orgId',
      substitutionValues: {'barcode': barcode, 'orgId': organizationId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final row = result.first;
    return _jsonResponse(
        200, jsonEncode(_rowToProduct(row, row[12] as String)));
  } finally {
    await connection.close();
  }
}

Future<Response> _updateProductHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canManageProducts(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final productId = int.parse(request.params['id']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final existing = await connection.query(
      'SELECT category_id FROM products '
      'WHERE id = @id AND organization_id = @orgId',
      substitutionValues: {'id': productId, 'orgId': organizationId},
    );
    if (existing.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }
    final categoryId = existing.first.first as int;

    final name = body['name'];
    final unit = body['unit'];
    final minStock = body['min_stock'];
    final maxStock = body['max_stock'];
    final hasMinStock = body.containsKey('min_stock');
    final hasMaxStock = body.containsKey('max_stock');
    final attributes = body['attributes'];

    if (name != null && name is! String) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }
    if (unit != null && unit is! String) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }
    if (hasMinStock && minStock is! num && minStock != null) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }
    if (hasMaxStock && maxStock is! num && maxStock != null) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }

    if (attributes != null || body.containsKey('attributes')) {
      if (attributes is! Map) {
        return _jsonResponse(400,
            '{"error":"invalid_attributes","details":["attributes must be an object"]}');
      }
      final schemaResult = await connection.query(
        'SELECT attribute_schema FROM product_categories WHERE id = @categoryId',
        substitutionValues: {'categoryId': categoryId},
      );
      final schema = schemaResult.first.first as List;
      final errors = validateAttributeValues(
          Map<String, dynamic>.from(attributes), schema);
      if (errors.isNotEmpty) {
        return _jsonResponse(
            400,
            jsonEncode({'error': 'invalid_attributes', 'details': errors}));
      }
    }

    final sets = <String>[];
    final values = <String, dynamic>{'id': productId};
    if (name != null) {
      sets.add('name = @name');
      values['name'] = name;
    }
    if (unit != null) {
      sets.add('unit = @unit');
      values['unit'] = unit;
    }
    if (hasMinStock) {
      sets.add('min_stock = @minStock');
      values['minStock'] = minStock;
    }
    if (hasMaxStock) {
      sets.add('max_stock = @maxStock');
      values['maxStock'] = maxStock;
    }
    if (body.containsKey('attributes')) {
      sets.add('attributes = @attributes::jsonb');
      values['attributes'] = jsonEncode(attributes);
    }
    if (sets.isEmpty) {
      return _jsonResponse(400, '{"error":"invalid_request"}');
    }

    await connection.execute(
      'UPDATE products SET ${sets.join(', ')} '
      'WHERE id = @id AND organization_id = @orgId',
      substitutionValues: {...values, 'orgId': organizationId},
    );

    final result = await connection.query(
      'SELECT p.id, p.organization_id, p.category_id, p.sku, p.barcode, '
      'p.name, p.unit, p.min_stock, p.max_stock, p.default_shelf_life_days, '
      'p.attributes, p.created_at, c.name '
      'FROM products p '
      'JOIN product_categories c ON c.id = p.category_id '
      'WHERE p.id = @id AND p.organization_id = @orgId',
      substitutionValues: {'id': productId, 'orgId': organizationId},
    );

    final row = result.first;
    return _jsonResponse(
        200, jsonEncode(_rowToProduct(row, row[12] as String)));
  } finally {
    await connection.close();
  }
}

/// Returns an error response if the user cannot view [warehouseId], else null.
/// Manager access requires super_admin or warehouse_manager role.
Future<Response?> _checkWarehouseAccess(
  int userId,
  int warehouseId, {
  bool manage = false,
}) async {
  final connection = await openConnection();
  try {
    final warehouseResult = await connection.query(
      'SELECT id FROM warehouses WHERE id = @id',
      substitutionValues: {'id': warehouseId},
    );
    if (warehouseResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final isSuper = await isSuperAdmin(userId);
    final role = await getUserRoleForWarehouse(userId, warehouseId);
    if (manage) {
      if (!isSuper && role != 'warehouse_manager') {
        return _jsonResponse(403, '{"error":"forbidden"}');
      }
    } else {
      if (!isSuper && role == null) {
        return _jsonResponse(403, '{"error":"forbidden"}');
      }
    }
    return null;
  } finally {
    await connection.close();
  }
}

Map<String, dynamic> _rowToZone(List row) {
  return {
    'id': row[0],
    'warehouse_id': row[1],
    'name': row[2],
    'zone_type': row[3],
    'created_at': (row[4] as DateTime).toUtc().toIso8601String(),
  };
}

Map<String, dynamic> _rowToStorageLocation(List row) {
  return {
    'id': row[0],
    'warehouse_id': row[1],
    'zone_id': row[2],
    'aisle': row[3],
    'rack': row[4],
    'shelf': row[5],
    'bin': row[6],
    'code': row[7],
    'capacity_units': _toNumOrNull(row[8]),
    'current_units': _toNumOrNull(row[9]),
    'created_at': (row[10] as DateTime).toUtc().toIso8601String(),
    'zone_name': row[11],
  };
}

const _storageLocationSelect = '''
SELECT sl.id, sl.warehouse_id, sl.zone_id, sl.aisle, sl.rack, sl.shelf, sl.bin,
       sl.code, sl.capacity_units, sl.current_units, sl.created_at, z.name
FROM storage_locations sl
LEFT JOIN zones z ON z.id = sl.zone_id
''';

const _storageLocationDetailSelect = '''
SELECT sl.id, sl.warehouse_id, sl.zone_id, sl.aisle, sl.rack, sl.shelf, sl.bin,
       sl.code, sl.capacity_units, sl.current_units, sl.created_at, z.name, w.name
FROM storage_locations sl
LEFT JOIN zones z ON z.id = sl.zone_id
JOIN warehouses w ON w.id = sl.warehouse_id
''';

Future<Response> _listZonesHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final access = await _checkWarehouseAccess(userId, warehouseId);
  if (access != null) return access;

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT id, warehouse_id, name, zone_type, created_at '
      'FROM zones WHERE warehouse_id = @warehouseId ORDER BY id',
      substitutionValues: {'warehouseId': warehouseId},
    );

    final zones = result.map((row) => _rowToZone(row)).toList();
    return _jsonResponse(200, jsonEncode(zones));
  } finally {
    await connection.close();
  }
}

Future<Response> _createZoneHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final access = await _checkWarehouseAccess(userId, warehouseId, manage: true);
  if (access != null) return access;

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final name = body['name'] as String?;
  final zoneType = body['zone_type'] as String?;
  if (name == null || name.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final result = await connection.query(
      'INSERT INTO zones (warehouse_id, name, zone_type) '
      'VALUES (@warehouseId, @name, @zoneType) '
      'RETURNING id, warehouse_id, name, zone_type, created_at',
      substitutionValues: {
        'warehouseId': warehouseId,
        'name': name,
        'zoneType': zoneType,
      },
    );
    return _jsonResponse(201, jsonEncode(_rowToZone(result.first)));
  } finally {
    await connection.close();
  }
}

Future<Response> _listStorageLocationsHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final access = await _checkWarehouseAccess(userId, warehouseId);
  if (access != null) return access;

  final zoneId = int.tryParse(request.url.queryParameters['zone_id'] ?? '');

  final connection = await openConnection();
  try {
    final conditions = <String>['sl.warehouse_id = @warehouseId'];
    final values = <String, dynamic>{'warehouseId': warehouseId};
    if (zoneId != null) {
      conditions.add('sl.zone_id = @zoneId');
      values['zoneId'] = zoneId;
    }

    final result = await connection.query(
      '$_storageLocationSelect WHERE ${conditions.join(' AND ')} ORDER BY sl.id',
      substitutionValues: values,
    );

    final locations =
        result.map((row) => _rowToStorageLocation(row)).toList();
    return _jsonResponse(200, jsonEncode(locations));
  } finally {
    await connection.close();
  }
}

Future<Response> _createStorageLocationHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final warehouseId = int.parse(request.params['id']!);

  final access =
      await _checkWarehouseAccess(userId, warehouseId, manage: true);
  if (access != null) return access;

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final zoneId = body['zone_id'] as int?;
  final aisle = body['aisle'] as String?;
  final rack = body['rack'] as String?;
  final shelf = body['shelf'] as String?;
  final bin = body['bin'] as String?;
  final capacityUnits = body['capacity_units'] as num?;
  if (aisle == null ||
      aisle.isEmpty ||
      rack == null ||
      rack.isEmpty ||
      shelf == null ||
      shelf.isEmpty ||
      bin == null ||
      bin.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final code = buildLocationCode(aisle, rack, shelf, bin);

  final connection = await openConnection();
  try {
    if (zoneId != null) {
      final zoneResult = await connection.query(
        'SELECT 1 FROM zones WHERE id = @zoneId AND warehouse_id = @warehouseId',
        substitutionValues: {'zoneId': zoneId, 'warehouseId': warehouseId},
      );
      if (zoneResult.isEmpty) {
        return _jsonResponse(404, '{"error":"not_found"}');
      }
    }

    final existing = await connection.query(
      'SELECT 1 FROM storage_locations '
      'WHERE warehouse_id = @warehouseId AND code = @code',
      substitutionValues: {'warehouseId': warehouseId, 'code': code},
    );
    if (existing.isNotEmpty) {
      return _jsonResponse(409, '{"error":"location_already_exists"}');
    }

    final result = await connection.query(
      'INSERT INTO storage_locations '
      '(warehouse_id, zone_id, aisle, rack, shelf, bin, code, capacity_units) '
      'VALUES (@warehouseId, @zoneId, @aisle, @rack, @shelf, @bin, @code, '
      '@capacityUnits) '
      'RETURNING id',
      substitutionValues: {
        'warehouseId': warehouseId,
        'zoneId': zoneId,
        'aisle': aisle,
        'rack': rack,
        'shelf': shelf,
        'bin': bin,
        'code': code,
        'capacityUnits': capacityUnits,
      },
    );
    final locationId = result.first.first as int;

    final fullResult = await connection.query(
      '$_storageLocationSelect WHERE sl.id = @id',
      substitutionValues: {'id': locationId},
    );
    return _jsonResponse(
        201, jsonEncode(_rowToStorageLocation(fullResult.first)));
  } finally {
    await connection.close();
  }
}

Future<Response> _getStorageLocationHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final locationId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final result = await connection.query(
      '$_storageLocationDetailSelect WHERE sl.id = @id',
      substitutionValues: {'id': locationId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final row = result.first;
    final isSuper = await isSuperAdmin(userId);
    final warehouseId = row[1] as int;
    final role = await getUserRoleForWarehouse(userId, warehouseId);
    if (!isSuper && role == null) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final location = _rowToStorageLocation(row);
    location['warehouse_name'] = row[12];
    return _jsonResponse(200, jsonEncode(location));
  } finally {
    await connection.close();
  }
}

Future<Response> _getStorageLocationByCodeHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final code = request.params['code']!;

  final connection = await openConnection();
  try {
    final isSuper = await isSuperAdmin(userId);

    final result = await connection.query(
      '$_storageLocationDetailSelect '
      'LEFT JOIN user_warehouse_access uwa '
      '  ON uwa.warehouse_id = sl.warehouse_id AND uwa.user_id = @userId '
      'WHERE sl.code = @code '
      'AND (@isSuper = TRUE OR uwa.id IS NOT NULL) '
      'ORDER BY sl.id LIMIT 1',
      substitutionValues: {
        'code': code,
        'userId': userId,
        'isSuper': isSuper,
      },
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final row = result.first;
    final location = _rowToStorageLocation(row);
    location['warehouse_name'] = row[12];
    return _jsonResponse(200, jsonEncode(location));
  } finally {
    await connection.close();
  }
}

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;

  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server running on http://localhost:${server.port}');
}
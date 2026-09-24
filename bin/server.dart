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
import 'package:wms_backend/inventory/expiry_alerts.dart';
import 'package:wms_backend/inventory/fefo_planner.dart';
import 'package:wms_backend/inventory/quality_workflow.dart';
import 'package:wms_backend/products/attribute_schema.dart';
import 'package:wms_backend/products/attribute_values.dart';
import 'package:wms_backend/products/batch_validation.dart';
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
  ..get('/products/<productId>/fefo-plan',
      authMiddleware()(_fefoPlanHandler))
  ..post('/products/<productId>/fefo-out',
      authMiddleware()(_fefoOutHandler))
  ..get('/alerts/expiring-batches',
      authMiddleware()(_expiringBatchesHandler))
  ..get('/alerts/summary', authMiddleware()(_alertsSummaryHandler))
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
      authMiddleware()(_getStorageLocationHandler))
  ..post('/products/<productId>/batches',
      authMiddleware()(_createBatchHandler))
  ..get('/products/<productId>/batches',
      authMiddleware()(_listBatchesHandler))
  ..get('/products/<productId>/locations',
      authMiddleware()(_listProductLocationsHandler))
  ..post('/batches/<batchId>/containers',
      authMiddleware()(_createBatchContainerHandler))
  ..get('/batches/<batchId>/containers',
      authMiddleware()(_listBatchContainersHandler))
  ..post('/batches/<id>/quality-status',
      authMiddleware()(_setBatchQualityStatusHandler))
  ..get('/batches/<id>/quality-history',
      authMiddleware()(_batchQualityHistoryHandler))
  ..get('/quality/pending',
      authMiddleware()(_qualityPendingHandler))
  ..get('/containers/barcode/<barcode>',
      authMiddleware()(_getContainerByBarcodeHandler))
  ..post('/inventory/out', authMiddleware()(_inventoryOutHandler))
  ..post('/inventory/transfer', authMiddleware()(_inventoryTransferHandler))
  ..post('/inventory/adjustment',
      authMiddleware()(_inventoryAdjustmentHandler))
  ..get('/inventory/transactions',
      authMiddleware()(_listInventoryTransactionsHandler));

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

Future<bool> _canOperateInventory(int userId) async {
  final connection = await openConnection();
  try {
    final result = await connection.query(
      'SELECT role FROM users WHERE id = @userId',
      substitutionValues: {'userId': userId},
    );
    if (result.isEmpty) return false;
    if (result.first.first == 'super_admin') return true;
    if (result.first.first == 'operator') return true;

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

String _dateToString(dynamic value) {
  if (value == null) return '';
  if (value is DateTime) {
    return value.toIso8601String().split('T').first;
  }
  return value.toString();
}

Map<String, dynamic> _rowToBatch(List row, {dynamic totalQuantity}) {
  return {
    'id': row[0],
    'organization_id': row[1],
    'product_id': row[2],
    'lot_number': row[3],
    'manufacture_date': _dateToString(row[4]),
    'expiry_date': _dateToString(row[5]),
    'received_date': _dateToString(row[6]),
    'quality_status': row[7],
    'created_at': (row[8] as DateTime).toUtc().toIso8601String(),
    'total_quantity': _toNumOrNull(totalQuantity) ?? 0,
  };
}

Map<String, dynamic> _rowToBatchContainer(List row) {
  return {
    'id': row[0],
    'batch_id': row[1],
    'container_barcode': row[2],
    'quantity': _toNumOrNull(row[3]),
    'location_id': row[4],
    'status': row[5],
    'created_at': (row[6] as DateTime).toUtc().toIso8601String(),
    'location_code': row[7],
  };
}

Future<Response?> _requireBatchInOrg(
    dynamic connection, int batchId, int organizationId) async {
  final result = await connection.query(
    'SELECT 1 FROM batches b '
    'JOIN products p ON p.id = b.product_id '
    'WHERE b.id = @batchId AND p.organization_id = @orgId',
    substitutionValues: {'batchId': batchId, 'orgId': organizationId},
  );
  if (result.isEmpty) {
    return _jsonResponse(404, '{"error":"not_found"}');
  }
  return null;
}

Future<Response> _createBatchHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canManageProducts(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final productId = int.parse(request.params['productId']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final lotNumber = body['lot_number'] as String?;
  final manufactureDate = body['manufacture_date'] as String?;
  final expiryDate = body['expiry_date'] as String?;
  final qualityStatus =
      body['quality_status'] as String? ?? 'pending_inspection';
  if (lotNumber == null || lotNumber.isEmpty) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (!isValidQualityStatus(qualityStatus)) {
    return _jsonResponse(400, '{"error":"invalid_quality_status"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final productResult = await connection.query(
      'SELECT 1 FROM products WHERE id = @productId AND organization_id = @orgId',
      substitutionValues: {'productId': productId, 'orgId': organizationId},
    );
    if (productResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final result = await connection.query(
      'INSERT INTO batches (organization_id, product_id, lot_number, '
      'manufacture_date, expiry_date, quality_status) '
      'VALUES (@orgId, @productId, @lotNumber, @manufactureDate, @expiryDate, '
      '@qualityStatus) '
      'RETURNING id, organization_id, product_id, lot_number, '
      'manufacture_date, expiry_date, received_date, quality_status, created_at',
      substitutionValues: {
        'orgId': organizationId,
        'productId': productId,
        'lotNumber': lotNumber,
        'manufactureDate': manufactureDate,
        'expiryDate': expiryDate,
        'qualityStatus': qualityStatus,
      },
    );
    final row = result.first;
    final batch = _rowToBatch(row, totalQuantity: 0);
    return _jsonResponse(201, jsonEncode(batch));
  } finally {
    await connection.close();
  }
}

Future<Response> _listBatchesHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final productId = int.parse(request.params['productId']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final productResult = await connection.query(
      'SELECT 1 FROM products WHERE id = @productId AND organization_id = @orgId',
      substitutionValues: {'productId': productId, 'orgId': organizationId},
    );
    if (productResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final result = await connection.query(
      'SELECT b.id, b.organization_id, b.product_id, b.lot_number, '
      'b.manufacture_date, b.expiry_date, b.received_date, b.quality_status, '
      'b.created_at, '
      'COALESCE((SELECT SUM(bc.quantity) FROM batch_containers bc '
      'WHERE bc.batch_id = b.id AND bc.status = \'active\'), 0) '
      'FROM batches b '
      'WHERE b.product_id = @productId '
      'ORDER BY b.expiry_date ASC NULLS LAST, b.id',
      substitutionValues: {'productId': productId},
    );

    final batches =
        result.map((row) => _rowToBatch(row, totalQuantity: row[9])).toList();
    return _jsonResponse(200, jsonEncode(batches));
  } finally {
    await connection.close();
  }
}

Future<Response> _createBatchContainerHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canManageProducts(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final batchId = int.parse(request.params['batchId']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final containerBarcode = body['container_barcode'] as String?;
  final quantity = body['quantity'] as num?;
  final locationId = body['location_id'] as int?;
  if (containerBarcode == null ||
      containerBarcode.isEmpty ||
      quantity == null) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final batchCheck = await _requireBatchInOrg(connection, batchId, organizationId);
    if (batchCheck != null) return batchCheck;

    if (locationId != null) {
      final locationResult = await connection.query(
        'SELECT 1 FROM storage_locations WHERE id = @locationId',
        substitutionValues: {'locationId': locationId},
      );
      if (locationResult.isEmpty) {
        return _jsonResponse(404, '{"error":"not_found"}');
      }
    }

    final existing = await connection.query(
      'SELECT 1 FROM batch_containers WHERE container_barcode = @barcode',
      substitutionValues: {'barcode': containerBarcode},
    );
    if (existing.isNotEmpty) {
      return _jsonResponse(409, '{"error":"barcode_already_exists"}');
    }

    await connection.execute(
      'INSERT INTO batch_containers '
      '(batch_id, container_barcode, quantity, location_id) '
      'VALUES (@batchId, @barcode, @quantity, @locationId)',
      substitutionValues: {
        'batchId': batchId,
        'barcode': containerBarcode,
        'quantity': quantity,
        'locationId': locationId,
      },
    );

    if (locationId != null) {
      await connection.execute(
        'UPDATE storage_locations SET current_units = current_units + @quantity '
        'WHERE id = @locationId',
        substitutionValues: {'quantity': quantity, 'locationId': locationId},
      );
    }

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status, bc.created_at, sl.code '
      'FROM batch_containers bc '
      'LEFT JOIN storage_locations sl ON sl.id = bc.location_id '
      'WHERE bc.batch_id = @batchId AND bc.container_barcode = @barcode',
      substitutionValues: {'batchId': batchId, 'barcode': containerBarcode},
    );

    return _jsonResponse(
        201, jsonEncode(_rowToBatchContainer(result.first)));
  } finally {
    await connection.close();
  }
}

Future<Response> _listBatchContainersHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final batchId = int.parse(request.params['batchId']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final batchCheck = await _requireBatchInOrg(connection, batchId, organizationId);
    if (batchCheck != null) return batchCheck;

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status, bc.created_at, sl.code '
      'FROM batch_containers bc '
      'LEFT JOIN storage_locations sl ON sl.id = bc.location_id '
      'WHERE bc.batch_id = @batchId ORDER BY bc.id',
      substitutionValues: {'batchId': batchId},
    );

    final containers =
        result.map((row) => _rowToBatchContainer(row)).toList();
    return _jsonResponse(200, jsonEncode(containers));
  } finally {
    await connection.close();
  }
}

Future<Response> _setBatchQualityStatusHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canManageProducts(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final batchId = int.parse(request.params['id']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final toStatus = body['status'] as String?;
  final note = body['note'] as String?;
  if (toStatus == null || !isValidQualityStatus(toStatus)) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (note == null || note.trim().isEmpty) {
    return _jsonResponse(400, '{"error":"note_required"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final batchResult = await connection.query(
      'SELECT b.quality_status FROM batches b '
      'JOIN products p ON p.id = b.product_id '
      'WHERE b.id = @batchId AND p.organization_id = @orgId',
      substitutionValues: {'batchId': batchId, 'orgId': organizationId},
    );
    if (batchResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }
    final fromStatus = batchResult.first.first as String;

    if (!isValidTransition(fromStatus, toStatus)) {
      return _jsonResponse(
        400,
        jsonEncode({
          'error': 'invalid_transition',
          'from': fromStatus,
          'to': toStatus,
        }),
      );
    }

    await connection.transaction((ctx) async {
      await ctx.execute(
        'UPDATE batches SET quality_status = @toStatus WHERE id = @batchId',
        substitutionValues: {'toStatus': toStatus, 'batchId': batchId},
      );
      await ctx.execute(
        'INSERT INTO quality_status_history '
        '(batch_id, from_status, to_status, note, changed_by) '
        'VALUES (@batchId, @fromStatus, @toStatus, @note, @changedBy)',
        substitutionValues: {
          'batchId': batchId,
          'fromStatus': fromStatus,
          'toStatus': toStatus,
          'note': note.trim(),
          'changedBy': userId,
        },
      );
    });

    final result = await connection.query(
      'SELECT b.id, b.organization_id, b.product_id, b.lot_number, '
      'b.manufacture_date, b.expiry_date, b.received_date, b.quality_status, '
      'b.created_at, '
      'COALESCE((SELECT SUM(bc.quantity) FROM batch_containers bc '
      'WHERE bc.batch_id = b.id AND bc.status = \'active\'), 0) '
      'FROM batches b WHERE b.id = @batchId',
      substitutionValues: {'batchId': batchId},
    );
    return _jsonResponse(
        200, jsonEncode(_rowToBatch(result.first, totalQuantity: result.first[9])));
  } finally {
    await connection.close();
  }
}

Future<Response> _batchQualityHistoryHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final batchId = int.parse(request.params['id']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final batchCheck =
        await _requireBatchInOrg(connection, batchId, organizationId);
    if (batchCheck != null) return batchCheck;

    final result = await connection.query(
      'SELECT qsh.id, qsh.batch_id, qsh.from_status, qsh.to_status, qsh.note, '
      'qsh.changed_by, qsh.changed_at, u.full_name '
      'FROM quality_status_history qsh '
      'JOIN users u ON u.id = qsh.changed_by '
      'WHERE qsh.batch_id = @batchId '
      'ORDER BY qsh.changed_at DESC, qsh.id DESC',
      substitutionValues: {'batchId': batchId},
    );

    final history = result
        .map((row) => {
              'id': row[0],
              'batch_id': row[1],
              'from_status': row[2],
              'to_status': row[3],
              'note': row[4],
              'changed_by': row[5],
              'changed_at': (row[6] as DateTime).toUtc().toIso8601String(),
              'changed_by_name': row[7],
            })
        .toList();
    return _jsonResponse(200, jsonEncode(history));
  } finally {
    await connection.close();
  }
}

Future<Response> _qualityPendingHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final roleResult = await connection.query(
      'SELECT role FROM users WHERE id = @userId',
      substitutionValues: {'userId': userId},
    );
    final isSuperAdmin =
        roleResult.isNotEmpty && roleResult.first.first == 'super_admin';

    final warehouseClause = isSuperAdmin
        ? ''
        : '''
      AND EXISTS (
        SELECT 1 FROM batch_containers bc2
        JOIN storage_locations sl2 ON sl2.id = bc2.location_id
        JOIN user_warehouse_access uwa ON uwa.warehouse_id = sl2.warehouse_id
        WHERE bc2.batch_id = b.id AND bc2.status = 'active'
          AND uwa.user_id = @userId
      )''';

    final result = await connection.query(
      '''
      SELECT b.id, b.product_id, p.name, b.lot_number, b.quality_status,
             b.received_date,
             COALESCE((SELECT SUM(bc.quantity) FROM batch_containers bc
             WHERE bc.batch_id = b.id AND bc.status = 'active'), 0)
      FROM batches b
      JOIN products p ON p.id = b.product_id
      WHERE b.organization_id = @organizationId
        AND b.quality_status IN ('pending_inspection', 'quarantine')
        $warehouseClause
      ORDER BY b.received_date ASC, b.id
      ''',
      substitutionValues: {'organizationId': organizationId, 'userId': userId},
    );

    final batches = result
        .map((row) => {
              'batch_id': row[0],
              'product_id': row[1],
              'product_name': row[2],
              'lot_number': row[3],
              'quality_status': row[4],
              'received_date': _dateToString(row[5]),
              'total_active_quantity': _toNumOrNull(row[6]),
            })
        .toList();
    return _jsonResponse(200, jsonEncode(batches));
  } finally {
    await connection.close();
  }
}

Future<Response> _getContainerByBarcodeHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final barcode = request.params['barcode']!;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status, bc.created_at, sl.code, '
      'p.name, p.sku, p.barcode, b.lot_number, b.expiry_date, b.quality_status, '
      'w.name '
      'FROM batch_containers bc '
      'JOIN batches b ON b.id = bc.batch_id '
      'JOIN products p ON p.id = b.product_id '
      'LEFT JOIN storage_locations sl ON sl.id = bc.location_id '
      'LEFT JOIN warehouses w ON w.id = sl.warehouse_id '
      'WHERE bc.container_barcode = @barcode '
      'AND p.organization_id = @orgId',
      substitutionValues: {'barcode': barcode, 'orgId': organizationId},
    );
    if (result.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final row = result.first;
    final container = _rowToBatchContainer(row);
    container['product_name'] = row[8];
    container['product_sku'] = row[9];
    container['product_barcode'] = row[10];
    container['lot_number'] = row[11];
    container['expiry_date'] = _dateToString(row[12]);
    container['quality_status'] = row[13];
    container['warehouse_name'] = row[14];
    return _jsonResponse(200, jsonEncode(container));
  } finally {
    await connection.close();
  }
}

Future<Response> _listProductLocationsHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final productId = int.parse(request.params['productId']!);

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final productResult = await connection.query(
      'SELECT 1 FROM products WHERE id = @productId AND organization_id = @orgId',
      substitutionValues: {'productId': productId, 'orgId': organizationId},
    );
    if (productResult.isEmpty) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final result = await connection.query(
      'SELECT sl.code, w.name, z.name, b.lot_number, b.expiry_date, '
      'bc.quantity '
      'FROM batch_containers bc '
      'JOIN batches b ON b.id = bc.batch_id '
      'JOIN storage_locations sl ON sl.id = bc.location_id '
      'JOIN warehouses w ON w.id = sl.warehouse_id '
      'LEFT JOIN zones z ON z.id = sl.zone_id '
      'WHERE b.product_id = @productId '
      'AND b.organization_id = @orgId '
      'AND bc.status = \'active\' '
      'ORDER BY sl.code, b.expiry_date',
      substitutionValues: {'productId': productId, 'orgId': organizationId},
    );

    final locations = result
        .map((row) => {
              'location_code': row[0],
              'warehouse_name': row[1],
              'zone_name': row[2],
              'lot_number': row[3],
              'expiry_date': _dateToString(row[4]),
              'quantity': _toNumOrNull(row[5]),
            })
        .toList();
    return _jsonResponse(200, jsonEncode(locations));
  } finally {
    await connection.close();
  }
}

/// Returns container row (id, batch_id, container_barcode, quantity,
/// location_id, status) if it belongs to [organizationId], else null.
Future<List?> _findContainerInOrg(
    dynamic connection, int containerId, int organizationId) async {
  final result = await connection.query(
    'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
    'bc.location_id, bc.status '
    'FROM batch_containers bc '
    'JOIN batches b ON b.id = bc.batch_id '
    'JOIN products p ON p.id = b.product_id '
    'WHERE bc.id = @containerId AND p.organization_id = @orgId',
    substitutionValues: {'containerId': containerId, 'orgId': organizationId},
  );
  if (result.isEmpty) return null;
  return result.first;
}

/// Returns a 404 response if [productId] does not belong to [organizationId].
Future<Response?> _requireProductInOrg(
    dynamic connection, int productId, int organizationId) async {
  final result = await connection.query(
    'SELECT 1 FROM products WHERE id = @productId AND organization_id = @orgId',
    substitutionValues: {'productId': productId, 'orgId': organizationId},
  );
  if (result.isEmpty) {
    return _jsonResponse(404, '{"error":"not_found"}');
  }
  return null;
}

/// Returns storage_location id if it exists and belongs to user's organization
/// (via its warehouse), else null.
Future<Response?> _requireLocationInOrg(
    dynamic connection, int locationId, int organizationId) async {
  final result = await connection.query(
    'SELECT 1 FROM storage_locations sl '
    'JOIN warehouses w ON w.id = sl.warehouse_id '
    'WHERE sl.id = @locationId AND w.organization_id = @orgId',
    substitutionValues: {'locationId': locationId, 'orgId': organizationId},
  );
  if (result.isEmpty) {
    return _jsonResponse(404, '{"error":"not_found"}');
  }
  return null;
}

Map<String, dynamic> _containerStateResponse(List container) {
  final quantity = _toNumOrNull(container[3]);
  return {
    'batch_container_id': container[0],
    'batch_id': container[1],
    'container_barcode': container[2],
    'quantity': quantity,
    'location_id': container[4],
    'status': container[5],
  };
}

Future<Response> _inventoryOutHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canOperateInventory(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final containerId = body['batch_container_id'] as int?;
  final quantity = body['quantity'] as num?;
  final note = body['note'] as String?;
  if (containerId == null || quantity == null || quantity <= 0) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final container = await _findContainerInOrg(connection, containerId, organizationId);
    if (container == null) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final batchStatusResult = await connection.query(
      'SELECT b.quality_status FROM batches b '
      'JOIN batch_containers bc ON bc.batch_id = b.id '
      'WHERE bc.id = @batchContainerId',
      substitutionValues: {'batchContainerId': containerId},
    );
    final qualityStatus =
        batchStatusResult.isNotEmpty ? batchStatusResult.first.first as String : '';
    if (qualityStatus != 'approved') {
      return _jsonResponse(
        400,
        jsonEncode({
          'error': 'batch_not_approved',
          'quality_status': qualityStatus,
        }),
      );
    }

    final currentQuantity = _toNumOrNull(container[3]) ?? 0;
    if (quantity > currentQuantity) {
      return _jsonResponse(
          400,
          jsonEncode({
            'error': 'insufficient_quantity',
            'available': currentQuantity,
          }));
    }

    final remaining = (currentQuantity - quantity).toDouble();
    final locationId = container[4] as int?;

    await connection.execute(
      'UPDATE batch_containers SET quantity = @remaining WHERE id = @containerId',
      substitutionValues: {'remaining': remaining, 'containerId': containerId},
    );

    if (locationId != null) {
      await connection.execute(
        'UPDATE storage_locations '
        'SET current_units = current_units - @quantity WHERE id = @locationId',
        substitutionValues: {'quantity': quantity, 'locationId': locationId},
      );
    }

    await connection.execute(
      'INSERT INTO inventory_transactions '
      '(organization_id, type, batch_container_id, from_location_id, '
      'quantity, performed_by, note) '
      'VALUES (@orgId, \'OUT\', @containerId, @locationId, @quantity, '
      '@performedBy, @note)',
      substitutionValues: {
        'orgId': organizationId,
        'containerId': containerId,
        'locationId': locationId,
        'quantity': quantity,
        'performedBy': userId,
        'note': note,
      },
    );

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status '
      'FROM batch_containers bc WHERE bc.id = @containerId',
      substitutionValues: {'containerId': containerId},
    );
    final state = _containerStateResponse(result.first);
    state['remaining_quantity'] = state['quantity'];
    state['quantity'] = quantity;
    return _jsonResponse(201, jsonEncode(state));
  } finally {
    await connection.close();
  }
}

Future<Response> _inventoryTransferHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canOperateInventory(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final containerId = body['batch_container_id'] as int?;
  final toLocationId = body['to_location_id'] as int?;
  final note = body['note'] as String?;
  if (containerId == null || toLocationId == null) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final container = await _findContainerInOrg(connection, containerId, organizationId);
    if (container == null) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final locCheck =
        await _requireLocationInOrg(connection, toLocationId, organizationId);
    if (locCheck != null) return locCheck;

    final quantity = _toNumOrNull(container[3]) ?? 0;
    final fromLocationId = container[4] as int?;

    if (fromLocationId != null) {
      await connection.execute(
        'UPDATE storage_locations '
        'SET current_units = current_units - @quantity WHERE id = @fromLocationId',
        substitutionValues: {'quantity': quantity, 'fromLocationId': fromLocationId},
      );
    }

    await connection.execute(
      'UPDATE storage_locations '
      'SET current_units = current_units + @quantity WHERE id = @toLocationId',
      substitutionValues: {'quantity': quantity, 'toLocationId': toLocationId},
    );

    await connection.execute(
      'UPDATE batch_containers SET location_id = @toLocationId '
      'WHERE id = @containerId',
      substitutionValues: {'toLocationId': toLocationId, 'containerId': containerId},
    );

    await connection.execute(
      'INSERT INTO inventory_transactions '
      '(organization_id, type, batch_container_id, from_location_id, '
      'to_location_id, quantity, performed_by, note) '
      'VALUES (@orgId, \'TRANSFER\', @containerId, @fromLocationId, '
      '@toLocationId, @quantity, @performedBy, @note)',
      substitutionValues: {
        'orgId': organizationId,
        'containerId': containerId,
        'fromLocationId': fromLocationId,
        'toLocationId': toLocationId,
        'quantity': quantity,
        'performedBy': userId,
        'note': note,
      },
    );

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status '
      'FROM batch_containers bc WHERE bc.id = @containerId',
      substitutionValues: {'containerId': containerId},
    );
    return _jsonResponse(201, jsonEncode(_containerStateResponse(result.first)));
  } finally {
    await connection.close();
  }
}

Future<Response> _inventoryAdjustmentHandler(Request request) async {
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

  final containerId = body['batch_container_id'] as int?;
  final newQuantity = body['new_quantity'] as num?;
  final note = body['note'] as String?;
  if (containerId == null || newQuantity == null || newQuantity < 0) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }
  if (note == null || note.trim().isEmpty) {
    return _jsonResponse(400, '{"error":"note_required"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final container = await _findContainerInOrg(connection, containerId, organizationId);
    if (container == null) {
      return _jsonResponse(404, '{"error":"not_found"}');
    }

    final oldQuantity = _toNumOrNull(container[3]) ?? 0;
    final delta = (newQuantity - oldQuantity).toDouble();
    final locationId = container[4] as int?;

    await connection.execute(
      'UPDATE batch_containers SET quantity = @newQuantity WHERE id = @containerId',
      substitutionValues: {'newQuantity': newQuantity, 'containerId': containerId},
    );

    if (locationId != null && delta != 0) {
      await connection.execute(
        'UPDATE storage_locations '
        'SET current_units = current_units + @delta WHERE id = @locationId',
        substitutionValues: {'delta': delta, 'locationId': locationId},
      );
    }

    await connection.execute(
      'INSERT INTO inventory_transactions '
      '(organization_id, type, batch_container_id, from_location_id, '
      'quantity, performed_by, note) '
      'VALUES (@orgId, \'ADJUSTMENT\', @containerId, @locationId, @delta, '
      '@performedBy, @note)',
      substitutionValues: {
        'orgId': organizationId,
        'containerId': containerId,
        'locationId': locationId,
        'delta': delta,
        'performedBy': userId,
        'note': note,
      },
    );

    final result = await connection.query(
      'SELECT bc.id, bc.batch_id, bc.container_barcode, bc.quantity, '
      'bc.location_id, bc.status '
      'FROM batch_containers bc WHERE bc.id = @containerId',
      substitutionValues: {'containerId': containerId},
    );
    final state = _containerStateResponse(result.first);
    state['delta'] = delta;
    return _jsonResponse(201, jsonEncode(state));
  } finally {
    await connection.close();
  }
}

Future<Response> _listInventoryTransactionsHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final batchContainerId =
        int.tryParse(request.url.queryParameters['batch_container_id'] ?? '');
    final locationId =
        int.tryParse(request.url.queryParameters['location_id'] ?? '');

    final conditions = <String>['it.organization_id = @orgId'];
    final values = <String, dynamic>{'orgId': organizationId};
    if (batchContainerId != null) {
      conditions.add('it.batch_container_id = @batchContainerId');
      values['batchContainerId'] = batchContainerId;
    }
    if (locationId != null) {
      conditions.add(
          '(it.from_location_id = @locationId OR it.to_location_id = @locationId)');
      values['locationId'] = locationId;
    }

    final result = await connection.query(
      'SELECT it.id, it.organization_id, it.type, it.batch_container_id, '
      'it.from_location_id, it.to_location_id, it.quantity, it.performed_by, '
      'it.note, it.created_at, u.full_name '
      'FROM inventory_transactions it '
      'JOIN users u ON u.id = it.performed_by '
      'WHERE ${conditions.join(' AND ')} '
      'ORDER BY it.created_at DESC, it.id DESC',
      substitutionValues: values,
    );

    final transactions = result
        .map((row) => {
              'id': row[0],
              'organization_id': row[1],
              'type': row[2],
              'batch_container_id': row[3],
              'from_location_id': row[4],
              'to_location_id': row[5],
              'quantity': _toNumOrNull(row[6]),
              'performed_by': row[7],
              'note': row[8],
              'created_at': (row[9] as DateTime).toUtc().toIso8601String(),
              'performed_by_name': row[10],
            })
        .toList();
    return _jsonResponse(200, jsonEncode(transactions));
  } finally {
    await connection.close();
  }
}

Future<Response> _fefoPlanHandler(Request request) async {
  final userId = request.context['userId'] as int;
  final productId = int.parse(request.params['productId']!);

  final quantity = num.tryParse(request.url.queryParameters['quantity'] ?? '');
  if (quantity == null || quantity <= 0) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final productCheck =
        await _requireProductInOrg(connection, productId, organizationId);
    if (productCheck != null) return productCheck;

    final plan = await buildFefoPlan(
      connection,
      userId: userId,
      organizationId: organizationId,
      productId: productId,
      requested: quantity,
    );

    return _jsonResponse(200, jsonEncode(plan.toJson()));
  } finally {
    await connection.close();
  }
}

Future<Response> _fefoOutHandler(Request request) async {
  final userId = request.context['userId'] as int;
  if (!await _canOperateInventory(userId)) {
    return _jsonResponse(403, '{"error":"forbidden"}');
  }

  final productId = int.parse(request.params['productId']!);

  final dynamic body;
  try {
    body = jsonDecode(await request.readAsString());
  } catch (_) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final quantity = body['quantity'] as num?;
  final note = body['note'] as String?;
  if (quantity == null || quantity <= 0) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final productCheck =
        await _requireProductInOrg(connection, productId, organizationId);
    if (productCheck != null) return productCheck;

    final executed = <Map<String, dynamic>>[];
    try {
      await connection.transaction((ctx) async {
        final plan = await buildFefoPlan(
          ctx,
          userId: userId,
          organizationId: organizationId,
          productId: productId,
          requested: quantity,
        );
        if (!plan.sufficient) {
          throw FefoInsufficientStock(plan.covered);
        }

        final barcodes = plan.plan.map((e) => e.containerBarcode).join(', ');
        final fullNote = [
          if (note != null && note.trim().isNotEmpty) note.trim(),
          '(FEFO avtomatik: $barcodes)',
        ].join(' ');

        for (final item in plan.plan) {
          await ctx.execute(
            'UPDATE batch_containers SET quantity = quantity - @qty '
            'WHERE id = @containerId',
            substitutionValues: {
              'qty': item.takeQuantity,
              'containerId': item.containerId,
            },
          );
          if (item.locationId != null) {
            await ctx.execute(
              'UPDATE storage_locations '
              'SET current_units = current_units - @qty WHERE id = @locationId',
              substitutionValues: {
                'qty': item.takeQuantity,
                'locationId': item.locationId,
              },
            );
          }
          await ctx.execute(
            'INSERT INTO inventory_transactions '
            '(organization_id, type, batch_container_id, from_location_id, '
            'quantity, performed_by, note) '
            'VALUES (@orgId, \'OUT\', @containerId, @locationId, @qty, '
            '@performedBy, @note)',
            substitutionValues: {
              'orgId': organizationId,
              'containerId': item.containerId,
              'locationId': item.locationId,
              'qty': item.takeQuantity,
              'performedBy': userId,
              'note': fullNote,
            },
          );
        }

        for (final item in plan.plan) {
          final row = await ctx.query(
            'SELECT quantity FROM batch_containers WHERE id = @containerId',
            substitutionValues: {'containerId': item.containerId},
          );
          final entry = item.toJson();
          entry['remaining_quantity'] = _toNumOrNull(row.first[0]);
          executed.add(entry);
        }
      });
    } on FefoInsufficientStock catch (e) {
      return _jsonResponse(
        400,
        jsonEncode({'error': 'insufficient_stock', 'available': e.available}),
      );
    }

    return _jsonResponseBody(201, {
      'requested': quantity,
      'covered': quantity,
      'sufficient': true,
      'plan': executed,
    });
  } finally {
    await connection.close();
  }
}

Future<Response> _expiringBatchesHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final rawDays = request.url.queryParameters['days'];
  final days = rawDays != null ? int.tryParse(rawDays) : 30;
  if (days == null || days < 0) {
    return _jsonResponse(400, '{"error":"invalid_request"}');
  }

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final items = await buildExpiryAlerts(
      connection,
      userId: userId,
      organizationId: organizationId,
      days: days,
    );

    return _jsonResponseBody(200, {'days': days, 'items': items});
  } finally {
    await connection.close();
  }
}

Future<Response> _alertsSummaryHandler(Request request) async {
  final userId = request.context['userId'] as int;

  final connection = await openConnection();
  try {
    final organizationId = await _getUserOrganizationId(connection, userId);
    if (organizationId == null) {
      return _jsonResponse(400, '{"error":"missing_organization"}');
    }

    final items = await buildExpiryAlerts(
      connection,
      userId: userId,
      organizationId: organizationId,
      days: 30,
    );

    return _jsonResponseBody(200, {
      'expired_count': items.where((e) => e['urgency'] == 'expired').length,
      'critical_count': items.where((e) => e['urgency'] == 'critical').length,
      'warning_count': items.where((e) => e['urgency'] == 'warning').length,
    });
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
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
      authMiddleware()(_getProductCategoryHandler));

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

void main(List<String> args) async {
  final ip = InternetAddress.anyIPv4;

  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server running on http://localhost:${server.port}');
}
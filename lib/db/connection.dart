import 'package:dotenv/dotenv.dart';
import 'package:postgres/postgres.dart';

Future<PostgreSQLConnection> openConnection() async {
  final env = DotEnv()..load();
  final uri = Uri.parse(env['DATABASE_URL']!);

  final userInfo = uri.userInfo;
  final username = userInfo.contains(':')
      ? userInfo.split(':').first
      : (userInfo.isNotEmpty ? userInfo : null);
  final password =
      userInfo.contains(':') ? userInfo.split(':').elementAt(1) : null;

  final connection = PostgreSQLConnection(
    uri.host,
    uri.hasPort ? uri.port : 5432,
    uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '',
    username: username,
    password: password,
    useSSL: uri.queryParameters['sslmode'] == 'require',
    allowClearTextPassword: true,
  );

  await connection.open();
  return connection;
}
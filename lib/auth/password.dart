import 'package:dbcrypt/dbcrypt.dart';

String hashPassword(String plain) {
  final bcrypt = DBCrypt();
  return bcrypt.hashpw(plain, bcrypt.gensalt());
}

bool verifyPassword(String plain, String hash) {
  return DBCrypt().checkpw(plain, hash);
}
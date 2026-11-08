/// Base class for all expected (user-presentable) failures in the app.
class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

class StorageException extends AppException {
  const StorageException(super.message, {super.cause});
}

class InsufficientStorageException extends StorageException {
  const InsufficientStorageException()
      : super('Not enough free storage on this device to complete the operation.');
}

class CorruptedFileException extends AppException {
  const CorruptedFileException(String what, {super.cause})
      : super('The file "$what" is damaged or in an unsupported format.');
}

class PasswordRequiredException extends AppException {
  const PasswordRequiredException() : super('This PDF is password protected.');
}

class WrongPasswordException extends AppException {
  const WrongPasswordException() : super('The password is incorrect.');
}

class PermissionDeniedException extends AppException {
  const PermissionDeniedException(String permission)
      : super('$permission permission was denied. You can enable it in system settings.');
}

class UnsupportedConversionException extends AppException {
  const UnsupportedConversionException(super.message);
}

/// Converts any thrown object into a short human readable message.
String describeError(Object error) {
  if (error is AppException) return error.message;
  final text = error.toString();
  if (text.contains('No space left') || text.contains('ENOSPC')) {
    return const InsufficientStorageException().message;
  }
  return text.replaceFirst('Exception: ', '');
}

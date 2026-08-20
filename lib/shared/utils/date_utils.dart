import 'package:intl/intl.dart';

class AppDateUtils {
  static String formatDisplayDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      return DateFormat('MMM d, yyyy').format(date);
    } catch (e) {
      return isoDate;
    }
  }

  static String formatShortDate(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      return DateFormat('d MMM').format(date);
    } catch (e) {
      return isoDate;
    }
  }

  static String formatIsoDate(DateTime date) {
    return DateFormat('yyyy-MM-dd').format(date);
  }

  static DateTime? parseLabDate(String dateStr) {
    final cleanStr = dateStr.trim();
    
    // Try standard ISO first
    try {
      return DateTime.parse(cleanStr);
    } catch (_) {}

    final formats = [
      'dd/MM/yyyy',
      'dd-MM-yyyy',
      'dd.MM.yyyy',
      'yyyy/MM/dd',
      'yyyy-MM-dd',
      'MM/dd/yyyy',
    ];

    for (var format in formats) {
      try {
        return DateFormat(format).parseStrict(cleanStr);
      } catch (_) {}
    }

    return null;
  }

  static String timeAgo(String isoDate) {
    try {
      final date = DateTime.parse(isoDate);
      final now = DateTime.now();
      final difference = now.difference(date);

      if (difference.inDays > 365) {
        final years = (difference.inDays / 365).floor();
        return '$years year${years > 1 ? 's' : ''} ago';
      } else if (difference.inDays > 30) {
        final months = (difference.inDays / 30).floor();
        return '$months month${months > 1 ? 's' : ''} ago';
      } else if (difference.inDays > 0) {
        return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
      } else if (difference.inHours > 0) {
        return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
      } else if (difference.inMinutes > 0) {
        return '${difference.inMinutes} minute${difference.inMinutes > 1 ? 's' : ''} ago';
      } else {
        return 'Just now';
      }
    } catch (e) {
      return '';
    }
  }
}

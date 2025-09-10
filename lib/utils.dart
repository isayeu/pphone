// utils.dart

String personalRoom(String fingerprint) {
  return 'personal_${fingerprint}';
}

String symmetricRoom(String fpA, String fpB) {
  final list = [fpA, fpB]..sort();
  return 'call_${list[0]}_${list[1]}';
}

// Более надежная проверка комнаты
bool isRoomForMe(String room, String myFp) {
  // Для персональных комнат: personal_<fingerprint>
  if (room.startsWith('personal_')) {
    return room == 'personal_$myFp';
  }

  // Для симметричных комнат: call_<fp1>_<fp2>
  if (room.startsWith('call_')) {
    final parts = room.split('_');
    if (parts.length == 3) { // Точное совпадение
      return parts[1] == myFp || parts[2] == myFp;
    }
  }

  return false;
}

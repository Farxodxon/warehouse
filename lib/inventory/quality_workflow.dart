/// Quality status transition rules for batches.
///
/// A batch starts at `pending_inspection` (or is created explicitly).
/// Only approved batches may be shipped out. `rejected` is a final state.
bool isValidTransition(String from, String to) {
  if (from == to) return false;
  switch (from) {
    case 'pending_inspection':
      return to == 'approved' || to == 'quarantine' || to == 'rejected';
    case 'quarantine':
      return to == 'approved' || to == 'rejected';
    case 'approved':
      // Recall scenario: pull an approved batch back.
      return to == 'quarantine' || to == 'rejected';
    case 'rejected':
      return false;
    default:
      return false;
  }
}
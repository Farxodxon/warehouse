const _allowedQualityStatuses = {
  'pending_inspection',
  'approved',
  'quarantine',
  'rejected',
};

const _allowedContainerStatuses = {'active', 'reserved', 'expired', 'damaged'};

bool isValidQualityStatus(String s) => _allowedQualityStatuses.contains(s);

bool isValidContainerStatus(String s) => _allowedContainerStatuses.contains(s);
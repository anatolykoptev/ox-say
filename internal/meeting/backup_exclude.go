package meeting

// backupExcludeValue is the extended-attribute value macOS itself writes when an item is excluded from backup
// (`tmutil addexclusion`, `URLResourceValues.isExcludedFromBackup`): a binary plist holding the string
// "com.apple.backupd". The bytes are the ones tmutil produced.
var backupExcludeValue = []byte{
	'b', 'p', 'l', 'i', 's', 't', '0', '0',
	0x5f, 0x10, 0x11, 'c', 'o', 'm', '.', 'a', 'p', 'p', 'l', 'e', '.', 'b', 'a', 'c', 'k', 'u', 'p', 'd',
	0x08,
	0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x1c,
}

// backupExcludeAttr is the extended attribute Time Machine and the other backup tools read.
const backupExcludeAttr = "com.apple.metadata:com_apple_backup_excludeItem"

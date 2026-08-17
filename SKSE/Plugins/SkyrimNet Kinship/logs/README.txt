This folder must exist before the mod can write snkin.log into it.

MiscUtil.WriteToFile does NOT create missing directories - it fails silently
and returns nothing. On the first live run the mod recorded 23 children to
SKSE\Plugins\StorageUtilData\SNKin_Parentage.json perfectly while producing no
log file at all, because this folder was not there and nothing said so.

That is why the folder ships with this placeholder inside it: an archive cannot
carry an empty directory, so without a file here the folder would not survive
packaging and the log would silently vanish again.

Do not delete this file unless snkin.log already exists alongside it.

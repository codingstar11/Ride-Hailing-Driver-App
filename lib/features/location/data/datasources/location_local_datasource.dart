// This file is retained as a thin facade over LocationHiveDatasource
// so that the repository interface stays unchanged and callers reference
// a consistent datasource type name across the codebase.

export '../../../../core/storage/location_hive_datasource.dart'
    show LocationHiveDatasource;

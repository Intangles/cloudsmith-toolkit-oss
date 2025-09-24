// MongoDB Script to Generate Collection Size Report in CSV Format
// Outputs: Collection Name, Data Size (MB), Index Size (MB), Total Size (MB)
// Sorted by collection size in descending order

function formatBytes(bytes) {
    return (bytes / 1024 / 1024).toFixed(2);
}

function generateCollectionSizeReport() {
    print("Collection Name,Data Size (MB),Index Size (MB),Total Size (MB),Document Count");
    
    var databases = db.adminCommand("listDatabases").databases;
    var allCollections = [];
    
    databases.forEach(function(database) {
        if (database.name !== "admin" && database.name !== "local" && database.name !== "config") {
            var currentDb = db.getSiblingDB(database.name);
            var collections = currentDb.getCollectionNames();
            
            collections.forEach(function(collectionName) {
                try {
                    var stats = currentDb.getCollection(collectionName).stats();
                    
                    var dataSize = stats.size || 0;
                    var indexSize = stats.totalIndexSize || 0;
                    var totalSize = dataSize + indexSize;
                    var docCount = stats.count || 0;
                    
                    allCollections.push({
                        name: database.name + "." + collectionName,
                        dataSize: dataSize,
                        indexSize: indexSize,
                        totalSize: totalSize,
                        docCount: docCount
                    });
                } catch (error) {
                    // Skip collections that can't be accessed
                    print("Error accessing " + database.name + "." + collectionName + ": " + error.message);
                }
            });
        }
    });
    
    // Sort by total size in descending order
    allCollections.sort(function(a, b) {
        return b.totalSize - a.totalSize;
    });
    
    // Print CSV data
    allCollections.forEach(function(collection) {
        print(collection.name + "," + 
              formatBytes(collection.dataSize) + "," + 
              formatBytes(collection.indexSize) + "," + 
              formatBytes(collection.totalSize) + "," + 
              collection.docCount);
    });
    
    // Print summary
    var totalDataSize = allCollections.reduce(function(sum, col) { return sum + col.dataSize; }, 0);
    var totalIndexSize = allCollections.reduce(function(sum, col) { return sum + col.indexSize; }, 0);
    var totalDocuments = allCollections.reduce(function(sum, col) { return sum + col.docCount; }, 0);
    
    print("");
    print("SUMMARY,,,,,");
    print("Total Collections," + allCollections.length + ",,,,");
    print("Total Data Size (MB)," + formatBytes(totalDataSize) + ",,,,");
    print("Total Index Size (MB)," + formatBytes(totalIndexSize) + ",,,,");
    print("Total Size (MB)," + formatBytes(totalDataSize + totalIndexSize) + ",,,,");
    print("Total Documents," + totalDocuments + ",,,,");
}

// Execute the report
generateCollectionSizeReport();

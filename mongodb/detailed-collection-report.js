// Enhanced MongoDB Collection Size Report Script
// Generates detailed CSV report with storage engine statistics

function formatBytes(bytes) {
    if (bytes === 0) return "0.00";
    return (bytes / 1024 / 1024).toFixed(2);
}

function formatNumber(num) {
    return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function generateDetailedCollectionReport() {
    print("Database,Collection,Data Size (MB),Index Size (MB),Total Size (MB),Document Count,Average Doc Size (KB),Storage Size (MB),Index Count");
    
    var databases = db.adminCommand("listDatabases").databases;
    var allCollections = [];
    
    databases.forEach(function(database) {
        // Skip system databases
        if (database.name === "admin" || database.name === "local" || database.name === "config") {
            return;
        }
        
        var currentDb = db.getSiblingDB(database.name);
        var collections = currentDb.getCollectionNames();
        
        collections.forEach(function(collectionName) {
            try {
                var collection = currentDb.getCollection(collectionName);
                var stats = collection.stats();
                
                var dataSize = stats.size || 0;
                var indexSize = stats.totalIndexSize || 0;
                var totalSize = dataSize + indexSize;
                var docCount = stats.count || 0;
                var storageSize = stats.storageSize || 0;
                var avgDocSize = docCount > 0 ? (dataSize / docCount / 1024) : 0; // in KB
                
                // Get index count
                var indexes = collection.getIndexes();
                var indexCount = indexes.length;
                
                allCollections.push({
                    database: database.name,
                    collection: collectionName,
                    dataSize: dataSize,
                    indexSize: indexSize,
                    totalSize: totalSize,
                    docCount: docCount,
                    avgDocSize: avgDocSize,
                    storageSize: storageSize,
                    indexCount: indexCount
                });
                
            } catch (error) {
                // Log error but continue
                print("# Error accessing " + database.name + "." + collectionName + ": " + error.message);
            }
        });
    });
    
    // Sort by total size in descending order
    allCollections.sort(function(a, b) {
        return b.totalSize - a.totalSize;
    });
    
    // Print CSV data
    allCollections.forEach(function(col) {
        print(col.database + "," + 
              col.collection + "," + 
              formatBytes(col.dataSize) + "," + 
              formatBytes(col.indexSize) + "," + 
              formatBytes(col.totalSize) + "," + 
              formatNumber(col.docCount) + "," + 
              col.avgDocSize.toFixed(2) + "," + 
              formatBytes(col.storageSize) + "," + 
              col.indexCount);
    });
    
    print("");
    print("# SUMMARY STATISTICS");
    print("# Total Collections: " + allCollections.length);
    
    if (allCollections.length > 0) {
        var totalDataSize = allCollections.reduce(function(sum, col) { return sum + col.dataSize; }, 0);
        var totalIndexSize = allCollections.reduce(function(sum, col) { return sum + col.indexSize; }, 0);
        var totalStorageSize = allCollections.reduce(function(sum, col) { return sum + col.storageSize; }, 0);
        var totalDocuments = allCollections.reduce(function(sum, col) { return sum + col.docCount; }, 0);
        var totalIndexes = allCollections.reduce(function(sum, col) { return sum + col.indexCount; }, 0);
        
        print("# Total Data Size: " + formatBytes(totalDataSize) + " MB");
        print("# Total Index Size: " + formatBytes(totalIndexSize) + " MB");
        print("# Total Storage Size: " + formatBytes(totalStorageSize) + " MB");
        print("# Total Documents: " + formatNumber(totalDocuments));
        print("# Total Indexes: " + totalIndexes);
        print("# Largest Collection: " + allCollections[0].database + "." + allCollections[0].collection + 
              " (" + formatBytes(allCollections[0].totalSize) + " MB)");
    }
}

// Print header information
print("# MongoDB Collection Size Report");
print("# Generated on: " + new Date().toISOString());
print("# Server: " + db.serverStatus().host);
print("# MongoDB Version: " + db.version());
print("");

// Execute the report
generateDetailedCollectionReport();

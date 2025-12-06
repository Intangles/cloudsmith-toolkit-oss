// MongoDB Script to Check Current Read and Write Concern Settings
// Compatible with MongoDB 4.4

print("=== MongoDB Read and Write Concern Status Check ===");
print("MongoDB Version:", db.version());
print("Connection:", db.serverStatus().host);
print("");

// 1. Check Current Write Concern
print("=== Current Write Concern Settings ===");
try {
    var writeSettings = db.runCommand({ getDefaultRWConcern: 1 });
    if (writeSettings.ok) {
        if (writeSettings.defaultWriteConcern) {
            print("Default Write Concern:");
            printjson(writeSettings.defaultWriteConcern);
        } else {
            print("No default write concern set (using MongoDB defaults)");
        }
    }
} catch (error) {
    print("Error getting write concern:", error.message);
}

// 2. Check Current Read Concern
print("\n=== Current Read Concern Settings ===");
try {
    var readSettings = db.runCommand({ getDefaultRWConcern: 1 });
    if (readSettings.ok) {
        if (readSettings.defaultReadConcern) {
            print("Default Read Concern:");
            printjson(readSettings.defaultReadConcern);
        } else {
            print("No default read concern set (using MongoDB defaults)");
        }
    }
} catch (error) {
    print("Error getting read concern:", error.message);
}

// 3. Check Replica Set Configuration
print("\n=== Replica Set Configuration ===");
try {
    var rsConfig = rs.conf();
    print("Replica Set Name:", rsConfig._id);
    print("Number of Members:", rsConfig.members.length);
    
    print("\nMembers:");
    rsConfig.members.forEach(function(member) {
        var priority = member.priority !== undefined ? member.priority : 1;
        var memberType = priority === 0 ? "ARBITER/SECONDARY" : 
                        member._id === 0 ? "PRIMARY" : "SECONDARY";
        print("  " + member.host + " (Priority: " + priority + ", Type: " + memberType + ")");
    });
    
    // Check if majority write concern is feasible
    var votingMembers = rsConfig.members.filter(function(member) {
        return member.votes !== 0;
    }).length;
    print("\nVoting Members:", votingMembers);
    print("Majority needed for 'majority' write concern:", Math.floor(votingMembers / 2) + 1);
    
} catch (error) {
    print("Error getting replica set config:", error.message);
}

// 4. Check Current Replica Set Status
print("\n=== Replica Set Status ===");
try {
    var rsStatus = rs.status();
    print("Set Name:", rsStatus.set);
    print("Current Primary:", rsStatus.members.find(function(m) { 
        return m.stateStr === "PRIMARY"; 
    }).name);
    
    print("\nMember States:");
    rsStatus.members.forEach(function(member) {
        print("  " + member.name + ": " + member.stateStr + 
              " (Health: " + member.health + ")");
    });
    
} catch (error) {
    print("Error getting replica set status:", error.message);
}


// db.adminCommand({
//   setDefaultRWConcern: 1,
//   defaultWriteConcern: { w: 1, j: true },
//   defaultReadConcern: { level: "local" }
// });
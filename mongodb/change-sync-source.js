// MongoDB Script to Change Sync Source for Replica Set Member
// Target: Change sync source for 172.31.38.88:27017 to sync from 172.31.41.223:27017

// First, let's check the current replica set status
print("=== Current Replica Set Status ===");
var status = rs.status();
print("Current sync sources:");
status.members.forEach(function(member) {
    if (member.syncSourceHost) {
        print("Member " + member.name + " syncs from: " + member.syncSourceHost);
    }
});

print("\n=== Changing Sync Source ===");

// Connect to the target secondary node (172.31.38.88:27017)
// Note: You need to run this command while connected to the target node
// or use db.adminCommand() if connected to primary

try {
    // Method 1: If you're connected to the target secondary (172.31.38.88:27017)
    var result = rs.syncFrom("172.31.41.223:27017");
    print("Sync source change result:", result);
    
    // Method 2: Alternative using adminCommand (can be run from any node)
    // var result = db.adminCommand({
    //     "replSetSyncFrom": "172.31.41.223:27017"
    // });
    // print("Sync source change result:", result);
    
} catch (error) {
    print("Error changing sync source:", error);
    print("\nPlease try one of these alternatives:");
    print("1. Connect directly to 172.31.38.88:27017 and run: rs.syncFrom('172.31.41.223:27017')");
    print("2. Run: db.adminCommand({replSetSyncFrom: '172.31.41.223:27017'})");
}

// Wait a moment and check the new status
print("\n=== Waiting 5 seconds for changes to take effect ===");
sleep(5000);

print("\n=== New Replica Set Status ===");
var newStatus = rs.status();
print("Updated sync sources:");
newStatus.members.forEach(function(member) {
    if (member.syncSourceHost) {
        print("Member " + member.name + " syncs from: " + member.syncSourceHost);
    }
});

// Specifically check our target member
var targetMember = newStatus.members.find(function(member) {
    return member.name === "172.31.38.88:27017";
});

if (targetMember) {
    print("\n=== Target Member Status ===");
    print("Member: " + targetMember.name);
    print("State: " + targetMember.stateStr);
    print("Sync Source: " + (targetMember.syncSourceHost || "None"));
    print("Health: " + targetMember.health);
    print("Uptime: " + targetMember.uptime + " seconds");
}

package listener

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/actions/scaleset"
)

// stubAdmin is the ScaleSetAdmin seam under test: a scripted, in-memory scale
// set registry that records every call. No live GitHub is reached -- the same
// interface-stub pattern the Session / Provisioner seams use, so the create /
// delete logic is exercised without credentials or a real scale set.
type stubAdmin struct {
	// sets is the fake server state. Names are unique only WITHIN a runner
	// group, exactly as on GitHub, so two groups may each hold a set with the
	// same name -- the high-availability layout this repo deploys.
	sets []*scaleset.RunnerScaleSet
	// lookups records the runner group id of every GetRunnerScaleSet call, so a
	// test can assert no lookup ever searched across groups (id 0).
	lookups []int
	// groups maps a runner group name to its id; a name absent here is
	// reported the way the real client reports an unknown group.
	groups map[string]int

	// created / deleted record what the admin was actually asked to do, so a
	// test can assert an idempotent path issued NO mutation at all.
	created []scaleset.RunnerScaleSet
	deleted []int

	getErr    error
	groupErr  error
	createErr error
	deleteErr error

	nextID int
}

func newStubAdmin() *stubAdmin {
	return &stubAdmin{
		groups: map[string]int{DefaultRunnerGroup: 1},
		nextID: 100,
	}
}

// GetRunnerScaleSet mirrors the real client's contract exactly, including the
// parts that matter most here: a scale set that does not exist is reported as
// (nil, nil), NOT as an error; group id 0 searches every group; and a name
// matching more than one set is an error ("multiple runner scale sets found").
func (s *stubAdmin) GetRunnerScaleSet(_ context.Context, groupID int, name string) (*scaleset.RunnerScaleSet, error) {
	s.lookups = append(s.lookups, groupID)
	if s.getErr != nil {
		return nil, s.getErr
	}
	var found []*scaleset.RunnerScaleSet
	for _, set := range s.sets {
		if set.Name == name && (groupID == 0 || set.RunnerGroupID == groupID) {
			found = append(found, set)
		}
	}
	switch len(found) {
	case 0:
		return nil, nil
	case 1:
		return found[0], nil
	default:
		return nil, errors.New("multiple runner scale sets found with name " + name)
	}
}

// seed puts a scale set straight into the fake server state, in a group.
func (s *stubAdmin) seed(id, groupID int, name string, labels ...string) {
	set := &scaleset.RunnerScaleSet{ID: id, Name: name, RunnerGroupID: groupID}
	for _, l := range labels {
		set.Labels = append(set.Labels, scaleset.Label{Name: l, Type: "System"})
	}
	s.sets = append(s.sets, set)
}

func (s *stubAdmin) GetRunnerGroupByName(_ context.Context, name string) (*scaleset.RunnerGroup, error) {
	if s.groupErr != nil {
		return nil, s.groupErr
	}
	id, ok := s.groups[name]
	if !ok {
		return nil, errors.New("no runner group found with name " + name)
	}
	return &scaleset.RunnerGroup{ID: id, Name: name}, nil
}

func (s *stubAdmin) CreateRunnerScaleSet(_ context.Context, set *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error) {
	if s.createErr != nil {
		return nil, s.createErr
	}
	s.created = append(s.created, *set)
	made := *set
	made.ID = s.nextID
	s.nextID++
	s.sets = append(s.sets, &made)
	return &made, nil
}

func (s *stubAdmin) DeleteRunnerScaleSet(_ context.Context, id int) error {
	if s.deleteErr != nil {
		return s.deleteErr
	}
	s.deleted = append(s.deleted, id)
	kept := s.sets[:0]
	for _, set := range s.sets {
		if set.ID != id {
			kept = append(kept, set)
		}
	}
	s.sets = kept
	return nil
}

// gpuType is the runner type the admin tests drive: the name and the labels
// deliberately DIFFER, because the whole point of driving this from the config
// is that the two are separate things -- workflows route on the labels.
func gpuType() RunnerType {
	return RunnerType{
		Name:     "gpu",
		ScaleSet: "gpu-runners",
		Labels:   []string{"self-hosted", "linux", "gpu"},
		Image:    "ghcr.io/acme/gpu-runner@sha256:abc",
	}
}

// Creating a scale set for a runner type uses the type's scale_set as the NAME
// and its labels as the LABELS -- never the name as a label. Getting this wrong
// is the failure that leaves every job sitting in queued forever, so it is
// pinned here rather than left to the client's "fill labels from the name"
// fallback.
func TestEnsureScaleSetCreatesWithConfiguredLabels(t *testing.T) {
	admin := newStubAdmin()

	res, err := EnsureScaleSet(context.Background(), admin, gpuType(), "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	if !res.Created {
		t.Error("first create should report Created")
	}
	if res.Name != "gpu-runners" {
		t.Errorf("Name = %q, want gpu-runners", res.Name)
	}
	if res.ID == 0 {
		t.Error("created scale set should carry the server-assigned id")
	}
	if len(admin.created) != 1 {
		t.Fatalf("issued %d creates, want 1", len(admin.created))
	}
	got := admin.created[0]
	if got.Name != "gpu-runners" {
		t.Errorf("created Name = %q, want gpu-runners", got.Name)
	}
	if got.RunnerGroupID != 1 {
		t.Errorf("created RunnerGroupID = %d, want 1 (the default group)", got.RunnerGroupID)
	}
	want := []string{"self-hosted", "linux", "gpu"}
	if len(got.Labels) != len(want) {
		t.Fatalf("created Labels = %v, want %v", got.Labels, want)
	}
	for i, l := range got.Labels {
		if l.Name != want[i] {
			t.Errorf("created label %d = %q, want %q", i, l.Name, want[i])
		}
	}
	// The type's own name must never leak into the routing labels.
	for _, l := range got.Labels {
		if l.Name == "gpu-runners" {
			t.Error("the scale set NAME must not be added as a routing label")
		}
	}
}

// Mode 1 (the default, no labels supplied): the routing labels become exactly
// the scale set name, so name and routing key coincide and a workflow simply
// writes `runs-on: <name>`.
//
// The value is set EXPLICITLY rather than left empty for the client's implicit
// auto-fill. The client only fills labels from the name when the field is
// empty, and relying on that implicitness is what produced the "job sits in
// queued forever" confusion: nothing written down anywhere said what the
// routing key actually was.
func TestEnsureScaleSetDefaultsLabelsToTheNameExplicitly(t *testing.T) {
	admin := newStubAdmin()
	rt := gpuType()
	rt.Labels = nil

	res, err := EnsureScaleSet(context.Background(), admin, rt, "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	sent := admin.created[0]
	if len(sent.Labels) != 1 || sent.Labels[0].Name != "gpu-runners" {
		t.Fatalf("sent Labels = %v, want exactly [gpu-runners] set explicitly", sent.Labels)
	}
	// The effective routing labels come back on the result, so the caller can
	// echo the exact runs-on line instead of guessing.
	if len(res.Labels) != 1 || res.Labels[0] != "gpu-runners" {
		t.Errorf("result Labels = %v, want [gpu-runners]", res.Labels)
	}
	if got := RunsOn(res.Labels); got != "runs-on: gpu-runners" {
		t.Errorf("RunsOn = %q, want %q", got, "runs-on: gpu-runners")
	}
}

// Mode 2 (explicit labels): the operator's labels are used verbatim, and the
// runs-on line renders them as the list form a workflow pastes.
func TestRunsOnRendersTheLiteralWorkflowLine(t *testing.T) {
	if got := RunsOn([]string{"self-hosted", "linux", "gpu"}); got != "runs-on: [self-hosted, linux, gpu]" {
		t.Errorf("RunsOn = %q", got)
	}
	if got := RunsOn(nil); got != "" {
		t.Errorf("RunsOn(nil) = %q, want empty", got)
	}
}

// A named runner group is resolved by name to its id, so an operator who keeps
// self-hosted runners in a non-default group can say so.
func TestEnsureScaleSetResolvesNamedRunnerGroup(t *testing.T) {
	admin := newStubAdmin()
	admin.groups["ci-hosts"] = 7

	if _, err := EnsureScaleSet(context.Background(), admin, gpuType(), "ci-hosts"); err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	if admin.created[0].RunnerGroupID != 7 {
		t.Errorf("RunnerGroupID = %d, want 7", admin.created[0].RunnerGroupID)
	}
}

// An unknown runner group fails closed, naming the group -- rather than
// silently creating the scale set in group 0.
func TestEnsureScaleSetUnknownGroupFails(t *testing.T) {
	admin := newStubAdmin()

	_, err := EnsureScaleSet(context.Background(), admin, gpuType(), "nope")
	if err == nil {
		t.Fatal("an unknown runner group must fail")
	}
	if !strings.Contains(err.Error(), "nope") {
		t.Errorf("error should name the group, got %v", err)
	}
	if len(admin.created) != 0 {
		t.Error("nothing may be created when the group cannot be resolved")
	}
}

// Idempotency: a second run over an existing scale set succeeds, reports "not
// created", returns the existing id, and issues NO create call -- so re-running
// the deploy on a second machine is safe and never produces a duplicate.
func TestEnsureScaleSetIsIdempotent(t *testing.T) {
	admin := newStubAdmin()
	rt := gpuType()

	first, err := EnsureScaleSet(context.Background(), admin, rt, "")
	if err != nil {
		t.Fatalf("first EnsureScaleSet: %v", err)
	}
	second, err := EnsureScaleSet(context.Background(), admin, rt, "")
	if err != nil {
		t.Fatalf("second EnsureScaleSet: %v", err)
	}
	if second.Created {
		t.Error("an existing scale set must not report Created")
	}
	if second.ID != first.ID {
		t.Errorf("second ID = %d, want the existing %d", second.ID, first.ID)
	}
	if len(admin.created) != 1 {
		t.Errorf("issued %d creates over two runs, want 1", len(admin.created))
	}
	if !second.LabelsMatch {
		t.Error("labels unchanged should report LabelsMatch")
	}
	// The existing scale set's live labels are what a workflow must target, so
	// they come back on the result too.
	if got := RunsOn(second.Labels); got != "runs-on: [self-hosted, linux, gpu]" {
		t.Errorf("RunsOn = %q", got)
	}
}

// An existing scale set whose labels no longer match the config is reported as
// a mismatch, listing the live labels. Silently reusing it would leave the
// operator with a config that says one thing and a routing target that does
// another -- the exact way jobs end up never being dispatched.
func TestEnsureScaleSetReportsLabelDrift(t *testing.T) {
	admin := newStubAdmin()
	admin.seed(42, 1, "gpu-runners", "gpu-runners")

	res, err := EnsureScaleSet(context.Background(), admin, gpuType(), "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	if res.Created {
		t.Error("an existing scale set must not report Created")
	}
	if res.LabelsMatch {
		t.Error("drifted labels must report a mismatch")
	}
	if len(res.LiveLabels) != 1 || res.LiveLabels[0] != "gpu-runners" {
		t.Errorf("LiveLabels = %v, want [gpu-runners]", res.LiveLabels)
	}
	if len(admin.created) != 0 {
		t.Error("a drifted scale set must not be re-created")
	}
}

// A lookup failure is a failure: the create must not proceed on "I could not
// tell whether it exists", which would risk a duplicate.
func TestEnsureScaleSetLookupErrorAborts(t *testing.T) {
	admin := newStubAdmin()
	admin.getErr = errors.New("boom")

	if _, err := EnsureScaleSet(context.Background(), admin, gpuType(), ""); err == nil {
		t.Fatal("a lookup error must abort the create")
	}
	if len(admin.created) != 0 {
		t.Error("nothing may be created after a failed lookup")
	}
}

// Deleting removes exactly the runner type's scale set, by its resolved id.
func TestDeleteScaleSetRemovesByResolvedID(t *testing.T) {
	admin := newStubAdmin()
	created, err := EnsureScaleSet(context.Background(), admin, gpuType(), "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}

	res, err := DeleteScaleSet(context.Background(), admin, gpuType(), "")
	if err != nil {
		t.Fatalf("DeleteScaleSet: %v", err)
	}
	if !res.Deleted {
		t.Error("an existing scale set should report Deleted")
	}
	if len(admin.deleted) != 1 || admin.deleted[0] != created.ID {
		t.Errorf("deleted = %v, want [%d]", admin.deleted, created.ID)
	}
}

// Deleting something that is not there is a no-op that succeeds and says so,
// so a teardown re-run does not fail on its own success.
func TestDeleteScaleSetAbsentIsNoOp(t *testing.T) {
	admin := newStubAdmin()

	res, err := DeleteScaleSet(context.Background(), admin, gpuType(), "")
	if err != nil {
		t.Fatalf("DeleteScaleSet: %v", err)
	}
	if res.Deleted {
		t.Error("an absent scale set must not report Deleted")
	}
	if len(admin.deleted) != 0 {
		t.Error("no delete call may be issued for an absent scale set")
	}
}

// ResolveScaleSet turns the client's "(nil, nil) means absent" contract into a
// clear, actionable error naming the create command. The production entrypoint
// used to dereference that nil, so a listener pointed at a scale set that does
// not exist yet crashed with a nil-pointer panic instead of telling the
// operator what to do.
func TestResolveScaleSetAbsentIsAnActionableError(t *testing.T) {
	admin := newStubAdmin()

	_, err := ResolveScaleSet(context.Background(), admin, "gpu-runners", "")
	if err == nil {
		t.Fatal("an absent scale set must be an error, not a nil dereference")
	}
	if !strings.Contains(err.Error(), "gpu-runners") {
		t.Errorf("error should name the scale set, got %v", err)
	}
	if !strings.Contains(err.Error(), "scaleset-admin create") {
		t.Errorf("error should point at the create command, got %v", err)
	}
}

// A resolvable scale set comes back whole.
func TestResolveScaleSetFound(t *testing.T) {
	admin := newStubAdmin()
	if _, err := EnsureScaleSet(context.Background(), admin, gpuType(), ""); err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}

	set, err := ResolveScaleSet(context.Background(), admin, "gpu-runners", "")
	if err != nil {
		t.Fatalf("ResolveScaleSet: %v", err)
	}
	if set.Name != "gpu-runners" {
		t.Errorf("Name = %q", set.Name)
	}
}

// SelectType is the shared "which runner type does this command act on" rule:
// a named type is looked up, and an unnamed one resolves only when the config
// holds exactly one type. It is shared by the listener and the admin command so
// the two can never disagree about which type a given config selects.
func TestSelectType(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, gpu]
    image: img@sha256:a
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, cpu]
    image: img@sha256:b
`)
	rt, err := SelectType(path, "cpu")
	if err != nil {
		t.Fatalf("SelectType: %v", err)
	}
	if rt.ScaleSet != "cpu-runners" {
		t.Errorf("ScaleSet = %q, want cpu-runners", rt.ScaleSet)
	}

	if _, err := SelectType(path, "nope"); err == nil {
		t.Error("an unknown type name must fail")
	}
	if _, err := SelectType(path, ""); err == nil {
		t.Error("an empty type name must fail when the config holds more than one type")
	}
}

// With exactly one type configured, the type need not be named.
func TestSelectTypeSoleTypeNeedsNoName(t *testing.T) {
	path := writeConfig(t, `
runner_types:
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, cpu]
    image: img@sha256:b
`)
	rt, err := SelectType(path, "")
	if err != nil {
		t.Fatalf("SelectType: %v", err)
	}
	if rt.Name != "cpu" {
		t.Errorf("Name = %q, want cpu", rt.Name)
	}
}

// The real client must be drop-in for the ScaleSetAdmin seam, so production
// hands a *scaleset.Client straight to these functions.
func TestClientSatisfiesScaleSetAdmin(t *testing.T) {
	var _ ScaleSetAdmin = (*scaleset.Client)(nil)
}

// DescribeType is the machine-readable report the deploy command reads instead
// of parsing the runner-type YAML itself. ADR-0003 makes the Go loader the
// authoritative parser; bash asks rather than re-implementing a second one.
//
// The shape is deliberately key=value lines: a shell can consume it with a
// single read loop, and adding a field cannot break an existing consumer.
func TestDescribeType(t *testing.T) {
	got := map[string]string{}
	for _, line := range DescribeType(gpuType()) {
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			t.Fatalf("line %q is not key=value", line)
		}
		got[k] = v
	}
	want := map[string]string{
		"name":       "gpu",
		"scale_set":  "gpu-runners",
		"labels":     "self-hosted,linux,gpu",
		"image":      "ghcr.io/acme/gpu-runner@sha256:abc",
		"runs_on":    "runs-on: [self-hosted, linux, gpu]",
		// No runner_group configured: the report states the group the type
		// actually resolves to, so the deploy tooling never has to guess.
		"runner_group": DefaultRunnerGroup,
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
}

// A type that declares no labels reports the routing labels it will actually
// get -- the scale set name -- not an empty field. A deploy command that
// printed nothing here would leave the operator guessing at the runs-on line,
// which is the whole failure this surface exists to prevent.
func TestDescribeTypeReportsTheEffectiveRoutingLabels(t *testing.T) {
	rt := gpuType()
	rt.Labels = nil
	got := map[string]string{}
	for _, line := range DescribeType(rt) {
		k, v, _ := strings.Cut(line, "=")
		got[k] = v
	}
	if got["labels"] != "gpu-runners" {
		t.Errorf("labels = %q, want gpu-runners", got["labels"])
	}
	if got["runs_on"] != "runs-on: gpu-runners" {
		t.Errorf("runs_on = %q, want %q", got["runs_on"], "runs-on: gpu-runners")
	}
}

// --- runner groups: the high-availability layout ---------------------------
//
// GitHub's documented failover pattern for runner scale sets is the SAME scale
// set name in DIFFERENT runner groups: one group per host, every host's set
// named `cpu`, identical labels. A job assigned to a scale set whose listener is
// down waits for that listener; spreading the name across groups is what lets
// another host's listener take the work. That makes a lookup "across all
// groups" (id 0) ambiguous, so every lookup here is pinned to one group.

// haAdmin is a fake org laid out the HA way: groups ci-kai (7) and ci-samuel
// (8), each holding a scale set named "cpu".
func haAdmin() *stubAdmin {
	admin := newStubAdmin()
	admin.groups["ci-kai"] = 7
	admin.groups["ci-samuel"] = 8
	admin.seed(70, 7, "cpu", "self-hosted", "linux", "cpu")
	admin.seed(80, 8, "cpu", "self-hosted", "linux", "cpu")
	return admin
}

func haCPUType(group string) RunnerType {
	return RunnerType{
		Name:        "cpu",
		ScaleSet:    "cpu",
		Labels:      []string{"self-hosted", "linux", "cpu"},
		Image:       "ghcr.io/acme/cpu@sha256:abc",
		RunnerGroup: group,
	}
}

// noCrossGroupLookup fails the test if any lookup searched across groups.
func noCrossGroupLookup(t *testing.T, admin *stubAdmin) {
	t.Helper()
	for _, id := range admin.lookups {
		if id == 0 {
			t.Errorf("a scale set lookup used runner group id 0 (all groups): %v", admin.lookups)
			return
		}
	}
}

// Two groups each hold a set named cpu: the listener resolves the one in ITS
// configured group, not whichever the server happens to match first (and not
// the "multiple scale sets" error a cross-group search gets).
func TestResolveScaleSetPicksTheConfiguredGroupsSet(t *testing.T) {
	admin := haAdmin()

	set, err := ResolveScaleSet(context.Background(), admin, "cpu", "ci-samuel")
	if err != nil {
		t.Fatalf("ResolveScaleSet: %v", err)
	}
	if set.ID != 80 {
		t.Errorf("resolved scale set id %d, want 80 (the ci-samuel one)", set.ID)
	}
	noCrossGroupLookup(t, admin)
}

// No group configured means the Default group -- resolved by name, never a
// cross-group search -- so an existing single-group install keeps working.
func TestResolveScaleSetEmptyGroupMeansDefault(t *testing.T) {
	admin := haAdmin()
	admin.seed(10, 1, "cpu", "self-hosted", "linux", "cpu")

	set, err := ResolveScaleSet(context.Background(), admin, "cpu", "")
	if err != nil {
		t.Fatalf("ResolveScaleSet: %v", err)
	}
	if set.ID != 10 {
		t.Errorf("resolved scale set id %d, want 10 (the Default-group one)", set.ID)
	}
	noCrossGroupLookup(t, admin)
}

// A runner group that does not exist is a clear error naming it -- not a
// fall-back to searching every group.
func TestResolveScaleSetUnknownGroupFails(t *testing.T) {
	admin := haAdmin()

	_, err := ResolveScaleSet(context.Background(), admin, "cpu", "ci-nobody")
	if err == nil {
		t.Fatal("an unknown runner group must fail")
	}
	if !strings.Contains(err.Error(), "ci-nobody") {
		t.Errorf("error should name the group, got %v", err)
	}
	if len(admin.lookups) != 0 {
		t.Errorf("no scale set lookup may run when the group is unknown, got %v", admin.lookups)
	}
}

// A set that exists in another group but not this one is "absent here": the
// error names both the set and the group, so the operator knows where to look.
func TestResolveScaleSetAbsentInGroupNamesTheGroup(t *testing.T) {
	admin := haAdmin()
	admin.groups["ci-nuc-002"] = 9

	_, err := ResolveScaleSet(context.Background(), admin, "cpu", "ci-nuc-002")
	if err == nil {
		t.Fatal("a set absent from the configured group must be an error")
	}
	if !strings.Contains(err.Error(), "ci-nuc-002") || !strings.Contains(err.Error(), "cpu") {
		t.Errorf("error should name the scale set and the group, got %v", err)
	}
}

// EnsureScaleSet creates in the type's runner_group when no --group is given,
// even though another group already holds a set with the same name.
func TestEnsureScaleSetCreatesInTheTypesRunnerGroup(t *testing.T) {
	admin := haAdmin()
	admin.groups["ci-nuc-002"] = 9

	res, err := EnsureScaleSet(context.Background(), admin, haCPUType("ci-nuc-002"), "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	if !res.Created {
		t.Fatal("a set absent from ci-nuc-002 must be created there, not reported as existing elsewhere")
	}
	if len(admin.created) != 1 || admin.created[0].RunnerGroupID != 9 {
		t.Errorf("created = %+v, want one create in group 9", admin.created)
	}
	if admin.created[0].RunnerGroupName != "ci-nuc-002" {
		t.Errorf("RunnerGroupName = %q, want ci-nuc-002", admin.created[0].RunnerGroupName)
	}
	noCrossGroupLookup(t, admin)
}

// Re-running create for a host whose group already holds the set is the
// idempotent no-op, and it reports THAT group's set.
func TestEnsureScaleSetIsIdempotentWithinTheGroup(t *testing.T) {
	admin := haAdmin()

	res, err := EnsureScaleSet(context.Background(), admin, haCPUType("ci-kai"), "")
	if err != nil {
		t.Fatalf("EnsureScaleSet: %v", err)
	}
	if res.Created || res.ID != 70 {
		t.Errorf("res = %+v, want the existing ci-kai set (id 70), not created", res)
	}
	if len(admin.created) != 0 {
		t.Error("an existing set must not be re-created")
	}
	noCrossGroupLookup(t, admin)
}

// A --group flag equal to the configured runner_group is fine; one that
// DIFFERS is an error with nothing looked up or created -- the config says one
// group and the flag another, and guessing which one is meant is how a set
// lands where the listener will never look for it.
func TestEnsureScaleSetFlagAndFieldConflict(t *testing.T) {
	admin := haAdmin()

	if _, err := EnsureScaleSet(context.Background(), admin, haCPUType("ci-kai"), "ci-kai"); err != nil {
		t.Fatalf("an agreeing --group must be accepted: %v", err)
	}

	admin = haAdmin()
	_, err := EnsureScaleSet(context.Background(), admin, haCPUType("ci-kai"), "ci-samuel")
	if err == nil {
		t.Fatal("a --group that differs from runner_group must fail")
	}
	if !strings.Contains(err.Error(), "ci-kai") || !strings.Contains(err.Error(), "ci-samuel") {
		t.Errorf("error should name both groups, got %v", err)
	}
	if len(admin.created) != 0 || len(admin.lookups) != 0 {
		t.Error("nothing may be looked up or created on a group conflict")
	}
}

// Delete removes the set in the type's group and leaves the same-named set in
// every other group alone.
func TestDeleteScaleSetDeletesOnlyTheGroupsSet(t *testing.T) {
	admin := haAdmin()

	res, err := DeleteScaleSet(context.Background(), admin, haCPUType("ci-kai"), "")
	if err != nil {
		t.Fatalf("DeleteScaleSet: %v", err)
	}
	if !res.Deleted || len(admin.deleted) != 1 || admin.deleted[0] != 70 {
		t.Errorf("deleted = %v (res %+v), want exactly [70]", admin.deleted, res)
	}
	noCrossGroupLookup(t, admin)

	if _, err := DeleteScaleSet(context.Background(), haAdmin(), haCPUType("ci-kai"), "ci-samuel"); err == nil {
		t.Error("delete with a --group that differs from runner_group must fail")
	}
}

// ResolveGroupName is the one rule both create/delete and the plan output use.
func TestResolveGroupName(t *testing.T) {
	for _, tc := range []struct {
		field, flag, want string
		wantErr           bool
	}{
		{"", "", DefaultRunnerGroup, false},
		{"", "ci-kai", "ci-kai", false},
		{"ci-kai", "", "ci-kai", false},
		{"ci-kai", "ci-kai", "ci-kai", false},
		{"ci-kai", "ci-samuel", "", true},
	} {
		got, err := ResolveGroupName(haCPUType(tc.field), tc.flag)
		if (err != nil) != tc.wantErr {
			t.Errorf("ResolveGroupName(field=%q, flag=%q) error = %v, wantErr %v", tc.field, tc.flag, err, tc.wantErr)
			continue
		}
		if got != tc.want {
			t.Errorf("ResolveGroupName(field=%q, flag=%q) = %q, want %q", tc.field, tc.flag, got, tc.want)
		}
	}
}

// show reports the configured runner_group verbatim.
func TestDescribeTypeReportsTheRunnerGroup(t *testing.T) {
	got := map[string]string{}
	for _, line := range DescribeType(haCPUType("ci-kai")) {
		k, v, _ := strings.Cut(line, "=")
		got[k] = v
	}
	if got["runner_group"] != "ci-kai" {
		t.Errorf("runner_group = %q, want ci-kai", got["runner_group"])
	}
}

package listener

import (
	"context"
	"fmt"
	"strings"

	"github.com/actions/scaleset"
)

// DefaultRunnerGroup is the runner group a scale set is created in when the
// operator names none. It is GitHub's standard group, the one every
// self-hosted runner lands in unless someone has deliberately organised them
// otherwise.
const DefaultRunnerGroup = "Default"

// ScaleSetAdmin is the subset of the official scale-set client
// (*scaleset.Client) the lifecycle commands drive: look a scale set up, look a
// runner group up, create, delete. Defining it as an interface here -- rather
// than taking the concrete client -- is the same seam Session and Provisioner
// use, and it is what lets the create/delete logic be unit-tested with no
// credentials and no live GitHub.
type ScaleSetAdmin interface {
	// GetRunnerScaleSet finds a scale set by name within a runner group.
	// IMPORTANT: the client reports "no such scale set" as (nil, nil), NOT as
	// an error -- see ResolveScaleSet. Group id 0 searches across groups; this
	// package never passes it (see lookupInGroup).
	GetRunnerScaleSet(ctx context.Context, runnerGroupID int, name string) (*scaleset.RunnerScaleSet, error)
	// GetRunnerGroupByName resolves a runner group name to its id.
	GetRunnerGroupByName(ctx context.Context, name string) (*scaleset.RunnerGroup, error)
	// CreateRunnerScaleSet creates a scale set. Names are unique within a
	// runner group.
	CreateRunnerScaleSet(ctx context.Context, set *scaleset.RunnerScaleSet) (*scaleset.RunnerScaleSet, error)
	// DeleteRunnerScaleSet deletes a scale set by id.
	DeleteRunnerScaleSet(ctx context.Context, id int) error
}

// The official client must be drop-in for the seam, so production hands a
// *scaleset.Client straight into these functions.
var _ ScaleSetAdmin = (*scaleset.Client)(nil)

// ScaleSetResult is the outcome of ensuring a runner type's scale set exists.
// It distinguishes "I made it" from "it was already there" so an idempotent
// re-run reports the truth rather than pretending it did work.
type ScaleSetResult struct {
	// Name is the scale set's name -- an identifier only. It is NOT what a
	// workflow's runs-on targets unless it also appears in Labels.
	Name string
	// ID is the server-assigned scale set id.
	ID int
	// Labels are the EFFECTIVE routing labels: what a workflow's runs-on must
	// match. On a create these are the labels that were written; on an
	// already-exists these are the labels the live scale set actually carries.
	Labels []string
	// Created is true only when this call created the scale set. False means
	// it was already there and nothing was mutated.
	Created bool
	// LabelsMatch reports whether the live scale set's labels equal the ones
	// the configuration asks for. Only meaningful when Created is false; a
	// false value means the config and the routing target disagree.
	LabelsMatch bool
	// LiveLabels are the labels the existing scale set carries when they
	// differ from the configured ones, so a mismatch can be reported concretely
	// instead of as "something is different".
	LiveLabels []string
}

// DeleteResult is the outcome of deleting a runner type's scale set. Deleted
// is false when there was nothing to delete -- a no-op that succeeded, not a
// failure, so a teardown re-run does not fail on its own success.
type DeleteResult struct {
	Name    string
	ID      int
	Deleted bool
}

// RoutingLabels are the labels a runner type's scale set routes on.
//
// THIS IS THE ROUTING KEY. A workflow's runs-on is matched against the scale
// set's LABELS; the scale set's name is only an identifier. Two modes:
//
//   - labels configured -> used verbatim, and the name is never added to them;
//   - no labels configured -> exactly the scale set name, so name and routing
//     key coincide and a workflow simply writes `runs-on: <name>`.
//
// The second mode is spelled out here rather than left to the client, which
// fills labels from the name only when the field arrives empty. Relying on
// that implicit fallback is what makes the routing key unwritten-down
// everywhere, which is exactly how a job ends up sitting in queued with no
// indication why. Whatever the routing key is, it is stated.
func RoutingLabels(rt RunnerType) []string {
	if len(rt.Labels) > 0 {
		return rt.Labels
	}
	return []string{rt.ScaleSet}
}

// RunsOn renders the literal workflow line that targets these labels, ready to
// paste: a single label as `runs-on: <label>`, several as the list form. Given
// that targeting the name instead of the labels is the mistake this whole
// surface exists to prevent, printing the exact line is more useful than any
// amount of explanation.
func RunsOn(labels []string) string {
	switch len(labels) {
	case 0:
		return ""
	case 1:
		return "runs-on: " + labels[0]
	default:
		return "runs-on: [" + strings.Join(labels, ", ") + "]"
	}
}

// labelNames flattens the client's label structs to plain names.
func labelNames(labels []scaleset.Label) []string {
	names := make([]string, 0, len(labels))
	for _, l := range labels {
		names = append(names, l.Name)
	}
	return names
}

// sameLabels reports whether two label sets are identical, order included. The
// order is part of it deliberately: the configuration is the source of truth,
// and a live scale set that lists the same labels in another order is still a
// scale set nobody's config describes.
func sameLabels(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ResolveGroupName reconciles a --group flag with the type's runner_group and
// returns the runner group to act in. The flag fills in when the config names
// no group; when both are given they must agree. Neither given means
// DefaultRunnerGroup.
//
// A disagreement is an error rather than "the flag wins": the listener resolves
// its scale set in the CONFIG's group, so a set created in the flag's group
// would be one the listener never finds.
func ResolveGroupName(rt RunnerType, flag string) (string, error) {
	switch {
	case flag == "":
		return rt.EffectiveRunnerGroup(), nil
	case rt.RunnerGroup == "" || rt.RunnerGroup == flag:
		return flag, nil
	default:
		return "", fmt.Errorf("--group %q contradicts runner type %q's runner_group %q; drop the flag or change the config",
			flag, rt.Name, rt.RunnerGroup)
	}
}

// lookupInGroup resolves a runner group by name and looks a scale set up
// WITHIN it. It never searches across groups (id 0): the high-availability
// layout gives every host the same scale set name in its own group, so a
// cross-group search is ambiguous -- the client answers it with "multiple
// runner scale sets found", or, with one match, silently returns another
// host's set. An empty groupName means DefaultRunnerGroup.
//
// The returned set is nil, with a nil error, when the group exists but holds
// no set of that name (the client's contract, kept).
func lookupInGroup(ctx context.Context, admin ScaleSetAdmin, name, groupName string) (*scaleset.RunnerGroup, *scaleset.RunnerScaleSet, error) {
	if groupName == "" {
		groupName = DefaultRunnerGroup
	}
	group, err := admin.GetRunnerGroupByName(ctx, groupName)
	if err != nil {
		return nil, nil, fmt.Errorf("resolve runner group %q: %w", groupName, err)
	}
	set, err := admin.GetRunnerScaleSet(ctx, group.ID, name)
	if err != nil {
		return nil, nil, fmt.Errorf("look up scale set %q in runner group %q: %w", name, groupName, err)
	}
	return group, set, nil
}

// EnsureScaleSet creates the GitHub scale set a runner type binds to, and is
// idempotent: if the scale set already exists in the type's runner group it is
// left exactly as it is and reported as such, so re-running the deploy on a
// machine performs no GitHub-side work at all.
//
// The name comes from the type's scale_set and the routing labels from
// RoutingLabels, so deploy/runner-types.yaml is the single source of truth for
// routing and the name/labels mismatch that strands jobs in queued cannot be
// introduced by a flag.
//
// groupFlag is the --group flag; the group acted in is ResolveGroupName's
// answer (the type's runner_group, else the flag, else DefaultRunnerGroup). An
// unresolvable group is an error with nothing created -- creating in group 0
// instead would put the scale set somewhere the operator did not ask for. A
// same-named set in ANOTHER group does not count as existing: that is another
// host's set in the high-availability layout.
func EnsureScaleSet(ctx context.Context, admin ScaleSetAdmin, rt RunnerType, groupFlag string) (ScaleSetResult, error) {
	groupName, err := ResolveGroupName(rt, groupFlag)
	if err != nil {
		return ScaleSetResult{}, err
	}
	labels := RoutingLabels(rt)

	// Look first. A lookup FAILURE is a failure: proceeding on "I could not
	// tell whether it exists" is how a duplicate gets created.
	group, existing, err := lookupInGroup(ctx, admin, rt.ScaleSet, groupName)
	if err != nil {
		return ScaleSetResult{}, err
	}
	if existing != nil {
		live := labelNames(existing.Labels)
		res := ScaleSetResult{
			Name:        existing.Name,
			ID:          existing.ID,
			Labels:      live,
			Created:     false,
			LabelsMatch: sameLabels(live, labels),
		}
		if !res.LabelsMatch {
			res.LiveLabels = live
		}
		return res, nil
	}

	// Labels are written EXPLICITLY, never left empty for the client to fill
	// from the name (see RoutingLabels).
	want := make([]scaleset.Label, 0, len(labels))
	for _, name := range labels {
		want = append(want, scaleset.Label{Name: name, Type: "System"})
	}
	created, err := admin.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name:            rt.ScaleSet,
		RunnerGroupID:   group.ID,
		RunnerGroupName: group.Name,
		Labels:          want,
	})
	if err != nil {
		return ScaleSetResult{}, fmt.Errorf("create scale set %q in runner group %q: %w", rt.ScaleSet, groupName, err)
	}
	return ScaleSetResult{
		Name:        created.Name,
		ID:          created.ID,
		Labels:      labelNames(created.Labels),
		Created:     true,
		LabelsMatch: true,
	}, nil
}

// DeleteScaleSet removes the GitHub scale set a runner type binds to, in the
// type's runner group (reconciled with groupFlag as for create). Same-named
// sets in other groups -- other hosts' sets in the high-availability layout --
// are never touched. Deleting is always an explicit act -- nothing else in this
// repo calls it -- and an absent scale set is a successful no-op so a teardown
// can be re-run.
func DeleteScaleSet(ctx context.Context, admin ScaleSetAdmin, rt RunnerType, groupFlag string) (DeleteResult, error) {
	groupName, err := ResolveGroupName(rt, groupFlag)
	if err != nil {
		return DeleteResult{}, err
	}
	_, existing, err := lookupInGroup(ctx, admin, rt.ScaleSet, groupName)
	if err != nil {
		return DeleteResult{}, err
	}
	if existing == nil {
		return DeleteResult{Name: rt.ScaleSet}, nil
	}
	if err := admin.DeleteRunnerScaleSet(ctx, existing.ID); err != nil {
		return DeleteResult{}, fmt.Errorf("delete scale set %q (id=%d): %w", existing.Name, existing.ID, err)
	}
	return DeleteResult{Name: existing.Name, ID: existing.ID, Deleted: true}, nil
}

// ResolveScaleSet fetches a scale set by name within a runner group (empty =
// DefaultRunnerGroup), turning the client's "(nil, nil) means absent" contract
// into an error that says what to do about it.
//
// The distinction matters: the production entrypoint used to dereference that
// nil, so a listener pointed at a scale set nobody had created yet died with a
// nil-pointer panic -- a stack trace where the operator needed one sentence.
//
// The group is resolved by name and the lookup is made in it, never across
// groups: with the same scale set name in one group per host, "any group" is
// ambiguous. An unknown group is an error naming it.
func ResolveScaleSet(ctx context.Context, admin ScaleSetAdmin, name, groupName string) (*scaleset.RunnerScaleSet, error) {
	if groupName == "" {
		groupName = DefaultRunnerGroup
	}
	_, set, err := lookupInGroup(ctx, admin, name, groupName)
	if err != nil {
		return nil, fmt.Errorf("get scale set %q: %w", name, err)
	}
	if set == nil {
		return nil, fmt.Errorf("no scale set named %q exists in runner group %q -- create it first with `scaleset-admin create`", name, groupName)
	}
	return set, nil
}

// SelectType loads the runner-type config and returns the one entry the caller
// acts on. A named type is looked up; an unnamed one resolves only when the
// config holds exactly one type, because a listener process (and an admin
// command) serves exactly one homogeneous scale set (ADR-0001).
//
// It is shared by the listener entrypoint and the admin command so the two can
// never disagree about which type a given config selects.
func SelectType(path, typeName string) (RunnerType, error) {
	types, err := LoadConfig(path)
	if err != nil {
		return RunnerType{}, err
	}
	if typeName == "" {
		if len(types) != 1 {
			return RunnerType{}, fmt.Errorf("name a runner type: %s configures %d of them", path, len(types))
		}
		return types[0], nil
	}
	for _, rt := range types {
		if rt.Name == typeName {
			return rt, nil
		}
	}
	return RunnerType{}, fmt.Errorf("no runner type named %q in %s", typeName, path)
}

// DescribeType renders a runner type as machine-readable key=value lines: what
// the type is called, the scale set it binds to, the EFFECTIVE routing labels,
// its image, the literal runs-on line a workflow needs, and the EFFECTIVE
// runner group the scale set lives in.
//
// It exists so the deploy tooling can learn a type's scale set and labels
// without parsing the runner-type YAML itself. ADR-0003 makes the Go loader the
// authoritative parser; a second parser in bash would be a copy that drifts,
// and it would drift on exactly the field (labels) that decides whether any job
// ever runs. So bash asks, and this is the answer.
//
// The labels reported are the effective ones (RoutingLabels), not the raw
// field: a type declaring none routes on its scale set name, and reporting an
// empty field would leave the caller to guess the very thing it asked about.
func DescribeType(rt RunnerType) []string {
	labels := RoutingLabels(rt)
	return []string{
		"name=" + rt.Name,
		"scale_set=" + rt.ScaleSet,
		"labels=" + strings.Join(labels, ","),
		"image=" + rt.Image,
		"runs_on=" + RunsOn(labels),
		// The EFFECTIVE group (Default when unset), for the same reason the
		// labels are effective: the caller asked which group, so answer it.
		"runner_group=" + rt.EffectiveRunnerGroup(),
	}
}

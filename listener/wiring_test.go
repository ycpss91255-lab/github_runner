package listener

import (
	"testing"
)

// A runner type maps to a listener Config bound to its scale set, image and
// runtime/device settings, so the type alone drives a listener
// instance (#112). mode: auto leaves MaxRunners 0 (the device detector sizes the
// bound) and attaches the detector, not the reactive probe.
func TestRunnerTypeToConfigAuto(t *testing.T) {
	det := stubDetector{count: 3}
	rt := RunnerType{
		Name:        "gpu",
		ScaleSet:    "gpu-runners",
		Labels:      []string{"self-hosted", "gpu"},
		Image:       "img-gpu@sha256:1",
		Devices:     []string{"/dev/nvidia0"},
		Runtime:     "nvidia",
		Concurrency: Concurrency{Mode: "auto"},
	}
	inst := rt.Instance(InstanceDeps{Detector: det, HostProbe: stubProbe{}})

	if inst.Config.HostProbe != nil {
		t.Error("device-sized type must not attach the reactive host probe")
	}
	if inst.ScaleSet != "gpu-runners" {
		t.Errorf("ScaleSet = %q, want gpu-runners", inst.ScaleSet)
	}
	if inst.Config.Image != "img-gpu@sha256:1" {
		t.Errorf("Image = %q", inst.Config.Image)
	}
	if inst.Config.MaxRunners != 0 {
		t.Errorf("auto concurrency should leave MaxRunners 0, got %d", inst.Config.MaxRunners)
	}
	if inst.Config.DeviceDetector == nil {
		t.Error("auto concurrency should attach the device detector")
	}
	// The type's precise device passthrough (#117) crosses into the listener
	// Config so the provisioner can pass exactly these as --device.
	if len(inst.Config.Devices) != 1 || inst.Config.Devices[0] != "/dev/nvidia0" {
		t.Errorf("Config.Devices = %v, want [/dev/nvidia0]", inst.Config.Devices)
	}
	// The type's container runtime shim crosses into the listener Config too, so
	// the provisioner can turn it into --runtime on the container run.
	if inst.Config.Runtime != "nvidia" {
		t.Errorf("Config.Runtime = %q, want nvidia", inst.Config.Runtime)
	}
	// The resolved bound should come from the detector (GPU count -> 3).
	l := New(nil, nil, nil, inst.Config)
	if l.bound != 3 {
		t.Errorf("resolved bound = %d, want 3 (GPU count)", l.bound)
	}
}

// The default (reactive) concurrency attaches the host probe and carries the
// reserve, and does NOT attach a device detector -- there is no fixed operator
// count; the concurrent-runner number is derived from live headroom (#163).
func TestRunnerTypeReactiveAttachesProbe(t *testing.T) {
	rt := RunnerType{
		Name:        "cpu",
		ScaleSet:    "cpu-runners",
		Labels:      []string{"self-hosted", "cpu"},
		Image:       "img-cpu@sha256:2",
		Concurrency: Concurrency{Reserve: 20},
	}
	inst := rt.Instance(InstanceDeps{Detector: stubDetector{count: 99}, HostProbe: stubProbe{}})

	if inst.Config.HostProbe == nil {
		t.Error("reactive concurrency should attach the host probe")
	}
	if inst.Config.Reserve != 20 {
		t.Errorf("Config.Reserve = %d, want 20", inst.Config.Reserve)
	}
	if inst.Config.DeviceDetector != nil {
		t.Error("reactive concurrency should not attach a device detector")
	}
}

// Two distinct types yield two independent instances bound to their own scale
// sets and images -- multiple types run side by side with no code change (#112).
func TestInstancesFromTypes(t *testing.T) {
	types := []RunnerType{
		{Name: "gpu", ScaleSet: "gpu-runners", Labels: []string{"gpu"}, Image: "g@sha256:1", Concurrency: Concurrency{Mode: "auto"}},
		{Name: "cpu", ScaleSet: "cpu-runners", Labels: []string{"cpu"}, Image: "c@sha256:2", Concurrency: Concurrency{Reserve: 10}},
	}
	insts := Instances(types, InstanceDeps{Detector: stubDetector{count: 1}, HostProbe: stubProbe{}})
	if len(insts) != 2 {
		t.Fatalf("got %d instances, want 2", len(insts))
	}
	if insts[0].ScaleSet != "gpu-runners" || insts[0].Config.Image != "g@sha256:1" {
		t.Errorf("instance 0 = %+v", insts[0])
	}
	if insts[0].Config.DeviceDetector == nil {
		t.Error("gpu instance should be device-sized")
	}
	if insts[1].ScaleSet != "cpu-runners" || insts[1].Config.HostProbe == nil {
		t.Errorf("cpu instance should be reactive, got %+v", insts[1])
	}
}

func TestRunnerTypeInstanceCopiesDockerSocket(t *testing.T) {
	const socket = "/var/run/docker.sock"
	rt := RunnerType{
		Name:         "cpu",
		ScaleSet:     "cpu-runners",
		Labels:       []string{"self-hosted", "cpu"},
		Image:        "img-cpu@sha256:2",
		DockerSocket: socket,
	}
	inst := rt.Instance(InstanceDeps{})
	if got := inst.Config.DockerSocket; got != socket {
		t.Errorf("Config.DockerSocket = %q, want %q", got, socket)
	}
}

// The instance carries the runner group the listener resolves its scale set
// in: the configured one, else Default -- never empty, which would mean "search
// every group" and is ambiguous once several groups hold a set of this name.
func TestRunnerTypeInstanceCarriesRunnerGroup(t *testing.T) {
	rt := RunnerType{Name: "cpu", ScaleSet: "cpu", Labels: []string{"cpu"}, Image: "i@sha256:1", RunnerGroup: "ci-kai"}
	if got := rt.Instance(InstanceDeps{}).RunnerGroup; got != "ci-kai" {
		t.Errorf("RunnerGroup = %q, want ci-kai", got)
	}
	rt.RunnerGroup = ""
	if got := rt.Instance(InstanceDeps{}).RunnerGroup; got != DefaultRunnerGroup {
		t.Errorf("RunnerGroup = %q, want %q", got, DefaultRunnerGroup)
	}
}

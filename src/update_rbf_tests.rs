// herdr-rbf: fork builds refuse upstream self-update and point at the install script (hrdr-5.2)
use super::*;

#[test]
fn install_command_is_the_fork_install_script() {
    assert_eq!(update_install_command(), "rbf/scripts/install-rbf.sh");
}

#[test]
fn install_instruction_names_the_script_and_the_handoff() {
    assert_eq!(
        update_install_instruction("rbf/scripts/install-rbf.sh"),
        "run `rbf/scripts/install-rbf.sh` from your herdr-rbf checkout; it hands running sessions to the new build"
    );
}

#[test]
fn channel_guidance_names_the_script_instead_of_self_update() {
    assert_eq!(
        package_manager_channel_update_guidance_for_current_install(),
        Some("Use `rbf/scripts/install-rbf.sh` from your herdr-rbf checkout to install herdr-rbf builds.")
    );
}

#[test]
fn self_update_is_refused_with_and_without_handoff() {
    for live_handoff in [false, true] {
        let result = self_update(SelfUpdateOptions { live_handoff });
        assert_eq!(
            result.err().as_deref(),
            Some(
                "self-update is disabled for herdr-rbf builds; run rbf/scripts/install-rbf.sh from your herdr-rbf checkout"
            ),
            "live_handoff: {live_handoff}"
        );
    }
}

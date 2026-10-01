"""Contract for canonical provider publication through the shared builder."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

class ProviderAstroWorkflow(unittest.TestCase):
    def test_provider_builds_preview_before_stable_with_isolated_versions(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/github-pages-deploy.yml').read_text())
        build = workflow['jobs']['build']
        step = next(item for item in build['steps'] if item.get('name') == 'Build docs with container')
        shell = step['run']
        self.assertNotIn('--entrypoint node', shell)
        self.assertNotIn('render-doc-collections', shell)
        self.assertLess(shell.index('preview_output='), shell.index('COLLECTION_ARGS=()'))
        self.assertIn('DOCS_BASE=/terraform-provider-xcsh/preview/main/', shell)
        self.assertIn('DOCS_BASE=/terraform-provider-xcsh/$prefix/', shell)
        self.assertIn('DOCS_PROFILE=canonical-provider', shell)
        self.assertIn('BUILDER_DIGEST=$BUILDER_IMAGE', shell)
        self.assertIn('canonical provider requires the accepted immutable builder', shell)
        verify = next(item for item in build['steps'] if item.get('name') == 'Verify build output')['run']
        self.assertIn('10000000000', verify)
        self.assertIn('Assembled Pages artifact:', verify)

if __name__ == '__main__':
    unittest.main()

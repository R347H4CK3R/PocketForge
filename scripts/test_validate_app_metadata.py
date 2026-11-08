import unittest
from validate_app_metadata import validate

class MetadataTests(unittest.TestCase):
    def test_valid(self):
        validate({'CFBundleIdentifier':'dev.pocketforge.studio','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'23'}, 'dev.pocketforge.studio')
    def test_missing_version(self):
        with self.assertRaises(ValueError):
            validate({'CFBundleIdentifier':'dev.pocketforge.studio','CFBundleVersion':'23'}, 'dev.pocketforge.studio')
    def test_placeholder_version(self):
        with self.assertRaises(ValueError):
            validate({'CFBundleIdentifier':'dev.pocketforge.studio','CFBundleShortVersionString':'$(MARKETING_VERSION)','CFBundleVersion':'23'}, 'dev.pocketforge.studio')
    def test_wrong_identity(self):
        with self.assertRaises(ValueError):
            validate({'CFBundleIdentifier':'other','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'23'}, 'dev.pocketforge.studio')

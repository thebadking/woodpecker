// Copyright 2025 Woodpecker Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package secret

import (
	"regexp"
	"sort"
	"strings"

	"go.woodpecker-ci.org/woodpecker/v3/server/model"
)

// SecretGroup represents a group of secrets organized by prefix
type SecretGroup struct {
	Name    string          `json:"name"`
	Secrets []*model.Secret `json:"secrets"`
}

// SecretGroups represents all secret groups including patterns
type SecretGroups struct {
	Groups   map[string][]*model.Secret `json:"groups"`
	Patterns []string                   `json:"patterns"`
}

// PrefixPattern represents a parsed prefix pattern
type PrefixPattern struct {
	Original       string         // Original pattern (e.g., "PROD_{??}")
	NormalizedBase string         // Base prefix without pattern (e.g., "PROD")
	Pattern        *regexp.Regexp // Compiled regex pattern
	IsTemplate     bool           // Whether it contains {?} or {*}
	Priority       int            // Higher priority = more specific pattern
}

// NormalizePrefix removes trailing _ or - and converts to uppercase
func NormalizePrefix(prefix string) string {
	prefix = strings.ToUpper(prefix)
	prefix = strings.TrimRight(prefix, "_-")
	return prefix
}

// ParsePrefixPattern parses a prefix pattern string into a PrefixPattern
func ParsePrefixPattern(pattern string) *PrefixPattern {
	pattern = strings.TrimSpace(pattern)
	if pattern == "" {
		return nil
	}

	pp := &PrefixPattern{
		Original: pattern,
	}

	// Check if it's a template pattern like PROD_{??} or PROD_{*}
	if strings.Contains(pattern, "{") && strings.Contains(pattern, "}") {
		pp.IsTemplate = true

		// Extract the base prefix (part before {)
		parts := strings.SplitN(pattern, "{", 2)
		base := NormalizePrefix(parts[0])
		pp.NormalizedBase = base

		// Extract the template part
		templatePart := parts[1]
		templatePart = strings.TrimSuffix(templatePart, "}")

		// Determine priority based on specificity
		// Fixed-length patterns (like {??}) have higher priority
		// Variable-length patterns (like {*}) have lower priority
		if strings.Contains(templatePart, "?") {
			questionCount := strings.Count(templatePart, "?")
			pp.Priority = 100 + questionCount // Higher priority for more specific length
			// Build regex: PROD_{??} -> ^PROD_([A-Z0-9]{2})_
			regexPattern := "^" + regexp.QuoteMeta(base) + "_([A-Z0-9]{" + string(rune('0'+questionCount)) + "})_"
			pp.Pattern = regexp.MustCompile(regexPattern)
		} else if templatePart == "*" {
			pp.Priority = 50 // Lower priority for wildcard
			// Build regex: PROD_{*} -> ^PROD_([A-Z0-9]+)_
			regexPattern := "^" + regexp.QuoteMeta(base) + "_([A-Z0-9]+)_"
			pp.Pattern = regexp.MustCompile(regexPattern)
		}
	} else {
		// Simple prefix pattern
		pp.IsTemplate = false
		pp.NormalizedBase = NormalizePrefix(pattern)
		pp.Priority = 10 // Lowest priority
		// Build regex: PROD -> ^PROD_
		regexPattern := "^" + regexp.QuoteMeta(pp.NormalizedBase) + "_"
		pp.Pattern = regexp.MustCompile(regexPattern)
	}

	return pp
}

// MatchSecret checks if a secret name matches this pattern and returns the group name
func (pp *PrefixPattern) MatchSecret(secretName string) (bool, string) {
	if pp.Pattern == nil {
		return false, ""
	}

	secretName = strings.ToUpper(secretName)

	if pp.IsTemplate {
		matches := pp.Pattern.FindStringSubmatch(secretName)
		if len(matches) > 1 {
			// Return the matched group name, e.g., "PROD_AE" for pattern "PROD_{??}"
			groupName := pp.NormalizedBase + "_" + matches[1]
			return true, groupName
		}
		return false, ""
	}

	// Simple prefix match
	if pp.Pattern.MatchString(secretName) {
		return true, pp.NormalizedBase
	}

	return false, ""
}

// GroupSecrets groups secrets based on prefix patterns
func GroupSecrets(secrets []*model.Secret, patterns []string) *SecretGroups {
	groups := make(map[string][]*model.Secret)
	groups["General"] = make([]*model.Secret, 0)

	// Parse all patterns
	parsedPatterns := make([]*PrefixPattern, 0, len(patterns))
	for _, pattern := range patterns {
		pp := ParsePrefixPattern(pattern)
		if pp != nil {
			parsedPatterns = append(parsedPatterns, pp)
		}
	}

	// Sort patterns by priority (highest first)
	sort.Slice(parsedPatterns, func(i, j int) bool {
		return parsedPatterns[i].Priority > parsedPatterns[j].Priority
	})

	// Group each secret
	for _, secret := range secrets {
		matched := false

		// Try to match against each pattern in priority order
		for _, pp := range parsedPatterns {
			isMatch, groupName := pp.MatchSecret(secret.Name)
			if isMatch {
				if groups[groupName] == nil {
					groups[groupName] = make([]*model.Secret, 0)
				}
				groups[groupName] = append(groups[groupName], secret)
				matched = true
				break // Use first matching pattern
			}
		}

		// If no pattern matched, add to General group
		if !matched {
			groups["General"] = append(groups["General"], secret)
		}
	}

	// Remove empty General group if all secrets were matched
	if len(groups["General"]) == 0 {
		delete(groups, "General")
	}

	return &SecretGroups{
		Groups:   groups,
		Patterns: patterns,
	}
}

// GetSortedGroupNames returns all group names sorted alphabetically with "General" first
func (sg *SecretGroups) GetSortedGroupNames() []string {
	names := make([]string, 0, len(sg.Groups))
	hasGeneral := false

	for name := range sg.Groups {
		if name == "General" {
			hasGeneral = true
		} else {
			names = append(names, name)
		}
	}

	sort.Strings(names)

	// Put "General" first if it exists
	if hasGeneral {
		names = append([]string{"General"}, names...)
	}

	return names
}

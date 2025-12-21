// Copyright 2024 Woodpecker Authors
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

package config

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/rs/zerolog/log"

	"go.woodpecker-ci.org/woodpecker/v3/server/forge"
	"go.woodpecker-ci.org/woodpecker/v3/server/forge/types"
	"go.woodpecker-ci.org/woodpecker/v3/server/model"
	"go.woodpecker-ci.org/woodpecker/v3/shared/constant"
)

type forgeFetcher struct {
	timeout    time.Duration
	retryCount uint
}

func NewForge(timeout time.Duration, retries uint) Service {
	return &forgeFetcher{
		timeout:    timeout,
		retryCount: retries,
	}
}

func (f *forgeFetcher) Fetch(ctx context.Context, forge forge.Forge, user *model.User, repo *model.Repo, pipeline *model.Pipeline, oldConfigData []*types.FileMeta, restart bool) (files []*types.FileMeta, err error) {
	// skip fetching if we are restarting and have the old config
	if restart && len(oldConfigData) > 0 {
		return oldConfigData, nil
	}

	ffc := &forgeFetcherContext{
		forge:    forge,
		user:     user,
		repo:     repo,
		pipeline: pipeline,
		timeout:  f.timeout,
	}

	// try to fetch multiple times
	for i := 0; i < int(f.retryCount); i++ {
		files, err = ffc.fetch(ctx, strings.TrimSpace(repo.Config))
		if err != nil {
			log.Trace().Err(err).Msgf("Fetching config files: Attempt #%d failed", i+1)
		} else {
			break
		}
	}

	return files, err
}

type forgeFetcherContext struct {
	forge    forge.Forge
	user     *model.User
	repo     *model.Repo
	pipeline *model.Pipeline
	timeout  time.Duration
}

// fetch attempts to fetch the configuration file(s) for the given config string.
func (f *forgeFetcherContext) fetch(c context.Context, config string) ([]*types.FileMeta, error) {
	ctx, cancel := context.WithTimeout(c, f.timeout)
	defer cancel()

	if len(config) > 0 {
		log.Trace().Msgf("configFetcher[%s]: use user config '%s'", f.repo.FullName, config)

		// could be adapted to allow the user to supply a list like we do in the defaults
		configs := []string{config}

		fileMetas, err := f.getFirstAvailableConfig(ctx, configs)
		if err == nil {
			return fileMetas, nil
		}

		return nil, fmt.Errorf("user defined config '%s' not found: %w", config, err)
	}

	log.Trace().Msgf("configFetcher[%s]: user did not define own config, following default procedure", f.repo.FullName)
	// for the order see shared/constants/constants.go
	fileMetas, err := f.getFirstAvailableConfig(ctx, constant.DefaultConfigOrder[:])
	if err == nil {
		return fileMetas, nil
	}

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	default:
		return nil, fmt.Errorf("configFetcher: fallback did not find config: %w", err)
	}
}

func (f *forgeFetcherContext) filterPipelineFiles(files []*types.FileMeta) []*types.FileMeta {
	var res []*types.FileMeta

	for _, file := range files {
		if strings.HasSuffix(file.Name, ".yml") || strings.HasSuffix(file.Name, ".yaml") {
			// Optionally ignore files with "template" in their name based on repo setting
			if f.repo.IgnoreTemplateFiles && strings.Contains(strings.ToLower(file.Name), "template") {
				continue
			}
			res = append(res, file)
		}
	}

	return res
}

func validateUniqueFileNames(files []*types.FileMeta) error {
	seen := make(map[string]string)
	for _, file := range files {
		// Extract the base name without extension and path
		baseName := strings.TrimSuffix(strings.TrimSuffix(file.Name, ".yml"), ".yaml")
		// Get just the filename without directory path
		parts := strings.Split(baseName, "/")
		fileName := parts[len(parts)-1]

		if existingPath, exists := seen[fileName]; exists {
			return fmt.Errorf("duplicate config file name '%s' found at paths: '%s' and '%s'", fileName, existingPath, file.Name)
		}
		seen[fileName] = file.Name
	}
	return nil
}

func (f *forgeFetcherContext) checkPipelineFile(c context.Context, config string) ([]*types.FileMeta, error) {
	file, err := f.forge.File(c, f.user, f.repo, f.pipeline, config)

	if err == nil && len(file) != 0 {
		log.Trace().Msgf("configFetcher[%s]: found file '%s'", f.repo.FullName, config)

		return []*types.FileMeta{{
			Name: config,
			Data: file,
		}}, nil
	}

	return nil, err
}

func (f *forgeFetcherContext) getFirstAvailableConfig(c context.Context, configs []string) ([]*types.FileMeta, error) {
	var forgeErr []error
	var debugInfo []string

	for _, fileOrFolder := range configs {
		log.Trace().Msgf("fetching %s from forge", fileOrFolder)
		if strings.HasSuffix(fileOrFolder, "/") {
			// config is a folder
			basePath := strings.TrimSuffix(fileOrFolder, "/")
			// Pass the configured depth to Dir()
			files, err := f.forge.Dir(c, f.user, f.repo, f.pipeline, basePath, f.repo.ConfigPathDepth)

			// if folder is not supported we will get a "Not implemented" error and continue
			if err != nil {
				if !errors.Is(err, types.ErrNotImplemented) && !errors.Is(err, &types.ErrConfigNotFound{}) {
					log.Error().Err(err).Str("repo", f.repo.FullName).Str("user", f.user.Login).Msgf("could not get folder from forge: %s", err)
					forgeErr = append(forgeErr, err)
					debugInfo = append(debugInfo, fmt.Sprintf("%s: error - %v", fileOrFolder, err))
				} else {
					debugInfo = append(debugInfo, fmt.Sprintf("%s: not found or not implemented", fileOrFolder))
				}
				continue
			}

			// Log what was returned before filtering
			allFileNames := make([]string, len(files))
			for i, file := range files {
				allFileNames[i] = file.Name
			}

			files = f.filterPipelineFiles(files)
			if len(files) != 0 {
				// Validate that all file names are unique
				if err := validateUniqueFileNames(files); err != nil {
					log.Error().Err(err).Str("repo", f.repo.FullName).Msgf("duplicate config file names found")
					return nil, err
				}
				fileNames := make([]string, len(files))
				for i, file := range files {
					fileNames[i] = file.Name
				}
				log.Info().Str("repo", f.repo.FullName).Msgf("found %d config files in '%s': %v", len(files), fileOrFolder, fileNames)
				return files, nil
			} else {
				msg := fmt.Sprintf("%s: found %d items but none are .yml/.yaml files: %v", fileOrFolder, len(allFileNames), allFileNames)
				log.Debug().Str("repo", f.repo.FullName).Msg(msg)
				debugInfo = append(debugInfo, msg)
			}
		}

		// config is a file
		if fileMeta, err := f.checkPipelineFile(c, fileOrFolder); err == nil {
			log.Info().Str("repo", f.repo.FullName).Msgf("found config file: '%s'", fileOrFolder)
			return fileMeta, nil
		} else if !errors.Is(err, &types.ErrConfigNotFound{}) {
			forgeErr = append(forgeErr, err)
			debugInfo = append(debugInfo, fmt.Sprintf("%s: error - %v", fileOrFolder, err))
		} else {
			debugInfo = append(debugInfo, fmt.Sprintf("%s: file not found", fileOrFolder))
		}
	}

	// got unexpected errors
	if len(forgeErr) != 0 {
		return nil, errors.Join(forgeErr...)
	}

	// nothing found - include debug info about what we checked
	log.Warn().Str("repo", f.repo.FullName).Msgf("No config found. Searched: %v", debugInfo)
	return nil, &types.ErrConfigNotFound{Configs: configs}
}

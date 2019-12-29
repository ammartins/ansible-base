pipeline {
  agent any
  options {
    parallelsAlwaysFailFast()
  }
  stages {
    stage('Instal Dependencies') {
      steps {
        sh '''
          pwd
          sudo pip install -r requirements.txt
        '''
      }
    }
    stage('Molecule Lint') {
      parallel {
        stage('Check Base') {
          steps {
            sh '''
              cd base
              molecule lint
            '''
          }
        }
      }
    }
    stage('Build docker image for Base') {
      when {
        not {
          branch 'master'
        }
      }
      steps {
        sh '''
          cd monitoring
          sudo molecule destroy
          sudo molecule converge
        '''
      }
    }
    stage('Cleanup docker') {
      when {
        not {
          branch 'master'
        }
      }
      steps {
        sh '''
          sudo docker stop $(sudo docker ps -q)
          sudo docker system prune -a -f
        '''
      }
    }
    stage('Cleanup docker') {
      when {
        branch 'master'
      }
      steps {
        sh '''
          sudo docker stop $(sudo docker ps -q)
          sudo docker system prune -a -f
        '''
      }
    }
  }
}
